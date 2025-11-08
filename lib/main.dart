// Clean rewritten file implementing audio visualizer (audioplayers + FFmpeg PCM repo)
// ignore_for_file: unnecessary_brace_in_string_interps

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show listEquals, compute;
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'pcm_repository.dart';

void _log(String msg, [Object? err, StackTrace? st]) {
  // Единый формат лога
  final buffer = StringBuffer('[AV] $msg');
  if (err != null) buffer.write(' | error=$err');
  if (st != null) buffer.write('\n$st');
  // Используем debugPrint (ограничение длины) + print fallback
  debugPrint(buffer.toString());
}

Future<void> main() async {
  // Глобальная зона для перехвата непойманных ошибок
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        _log('FlutterError', details.exception, details.stack);
      };
      runApp(const MyApp());
    },
    (error, stack) {
      _log('Uncaught zone error', error, stack);
    },
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music Visio',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const AudioVisualizerPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AudioVisualizerPage extends StatefulWidget {
  const AudioVisualizerPage({super.key});

  @override
  State<AudioVisualizerPage> createState() => _AudioVisualizerPageState();
}

class _AudioVisualizerPageState extends State<AudioVisualizerPage> {
  final _player = AudioPlayer();
  StreamSubscription<Duration>? _posSub;
  Duration _lastPos = Duration.zero;
  PcmRepository? _pcmRepo;
  bool _decodeReady = false;
  String _decodeInfo = '';
  List<double> _fft =
      const []; // raw linear spectrum (may be unused if log bands enabled)
  // Log-band visualization state
  bool _useLogBands = true; // переключатель логарифмических полос
  bool _useIsoBands = true; // ISO 1/3-octave centers for "standard" look
  static const int _defaultLogBandCount = 32;
  List<double>? _logBands; // текущее значение полос 0..1
  List<double> _peakHold = List.filled(_defaultLogBandCount, 0.0);
  List<double>? _prevLogBands; // для EMA
  double _emaAlpha = 0.5; // сглаживание полос (0..0.95). Ниже — быстрее реакция
  Timer? _timer;
  bool _isPlaying = false;
  double _peak = 0;
  List<double>? _prevSpectrum; // для сглаживания между кадрами
  int _frameCount = 0; // счетчик кадров для условного логирования
  // Настройки визуализации
  int _windowSamples = 256;
  int _updateIntervalMs = 60; // таймер перерисовки
  int _fullComputeIntervalMs = 250; // период полного пересчета спектра
  bool _useFft = true; // режим FFT или Wave fallback
  bool _decayBetweenUpdates = true; // затухание между полными апдейтами
  double _decayFactor =
      0.96; // множитель затухания между апдейтами (0.90..0.999)
  // Безопасный старт: не читать сэмплы в первые N мс после старта проигрывания
  final int _safeStartMs = 1200; // немного увеличим для диагностики падения
  DateTime? _playStartedAt;
  bool _visualizationMasterEnabled =
      true; // глобальный выключатель визуализации
  Timer? _heartbeatTimer; // периодический лог для отслеживания жизни процесса

  @override
  void initState() {
    super.initState();
    _initPlayback();
    _startHeartbeat();
    if (_visualizationMasterEnabled) {
      _startFftPolling();
    } else {
      _log('Visualization master OFF: spectrum disabled.');
    }
  }

  Future<void> _initPlayback() async {
    try {
      // 1) Подготавливаем PCM репозиторий (FFmpeg decode офлайн)
      final repo = PcmRepository(
        assetPath: 'assets/audio/sample.mp3',
        stereo: true, // стерео для плеера, моно смешаем для визуализации
        sampleRate: 44100,
      );
      await repo.ensureReady();
      _pcmRepo = repo;
      _decodeReady = true;
      _decodeInfo =
          'PCM ready: ${repo.sampleRate} Hz, ch=${repo.channels}, totalFrames=${repo.totalFrames}';

      // 2) Инициализируем аудио-плеер и запускаем воспроизведение исходного mp3 из assets
      // Для audioplayers путь указывается относительно корня assets в pubspec
      await _player.play(AssetSource('audio/sample.mp3'));
      // Subscribe to position updates to avoid awaiting getCurrentPosition each tick
      _posSub?.cancel();
      _posSub = _player.onPositionChanged.listen((d) {
        _lastPos = d;
      });
      setState(() {
        _isPlaying = true;
      });
      _playStartedAt = DateTime.now();
      _log('Playback started (audioplayers)');
    } catch (e, st) {
      _log('Init playback failed', e, st);
    }
  }

  void _startFftPolling() {
    if (!_visualizationMasterEnabled) return; // не запускаем если выключено
    // Максимум частоты спектра = sampleRate/2.
    const smoothing = 0.6; // сглаживание между кадрами

    // FPS/временное логирование
    const int _logEveryMs = 500; // раз в 500 мс
    int framesSinceLastLog = 0;
    int lastLogStampMs = DateTime.now().millisecondsSinceEpoch;

    bool busy = false;
    DateTime lastCompute = DateTime.fromMillisecondsSinceEpoch(0);
    _timer?.cancel();
    _timer = Timer.periodic(Duration(milliseconds: _updateIntervalMs), (
      _,
    ) async {
      if (busy || !mounted) return;
      busy = true;
      try {
        if (!_visualizationMasterEnabled) return; // двойная защита
        final repo = _pcmRepo;
        if (!_decodeReady || repo == null) return;
        final posMs = _lastPos.inMilliseconds.toDouble();
        final pos = posMs / 1000.0;
        if (pos <= 0) return;

        final now = DateTime.now();
        // Безопасный старт: не трогаем чтение сэмплов первые _safeStartMs мс
        final started = _playStartedAt;
        if (started != null &&
            now.difference(started).inMilliseconds < _safeStartMs) {
          return;
        }
        final mustRecompute =
            now.difference(lastCompute).inMilliseconds >=
            _fullComputeIntervalMs;

        List<double>? limited;
        double peak = _peak;
        if (mustRecompute) {
          lastCompute = now;

          final windowSamples = _windowSamples;
          final sr = repo.sampleRate;
          final endFrame = (pos * sr).round();
          final samples = await repo.readMonoWindow(endFrame, windowSamples);
          if (samples.isEmpty) return;

          List<double> normSpec;
          if (_useFft) {
            try {
              final spectrum = await compute(_computeSpectrumIsolate, samples);
              // Если включены лог полосы — не преобразуем в лог сразу, оставляем magnitudes
              if (_useLogBands) {
                normSpec = spectrum; // передадим для дальнейшего маппинга
              } else {
                normSpec = List<double>.generate(spectrum.length, (i) {
                  final v = spectrum[i];
                  return log(1 + v * 50) / log(51); // 0..1
                });
              }
            } catch (e) {
              _log(
                'Isolate FFT error, fallback to wave',
                e is Exception ? e : Exception(e),
              );
              normSpec = _waveFallback(samples);
            }
          } else {
            normSpec = _waveFallback(samples);
          }

          if (_prevSpectrum != null &&
              _prevSpectrum!.length == normSpec.length) {
            for (int i = 0; i < normSpec.length; i++) {
              normSpec[i] =
                  smoothing * _prevSpectrum![i] + (1 - smoothing) * normSpec[i];
            }
          }
          _prevSpectrum = normSpec;

          if (_useLogBands && _useFft) {
            final mapped = _useIsoBands
                ? _mapFftToIsoBands(
                    magnitudes: normSpec,
                    sampleRate: repo.sampleRate,
                    prevBands: _prevLogBands,
                    emaAlpha: _emaAlpha,
                  )
                : _mapFftToLogBands(
                    magnitudes: normSpec, // реальные спектральные амплитуды
                    sampleRate: repo.sampleRate,
                    bands: _defaultLogBandCount,
                    prevBands: _prevLogBands,
                    emaAlpha: _emaAlpha,
                  );
            _prevLogBands = mapped;
            // Peak hold обновление
            _ensurePeakHoldLength(mapped.length);
            for (int i = 0; i < mapped.length; i++) {
              if (mapped[i] > _peakHold[i]) {
                _peakHold[i] = mapped[i];
              } else {
                _peakHold[i] = (_peakHold[i] - 0.01).clamp(0.0, 1.0);
              }
            }
            _logBands = mapped;
            peak = mapped.isEmpty ? 0.0 : mapped.reduce(max);
            limited =
                mapped; // для совместимости старого painter если переключим
          } else {
            limited = normSpec.length > 256
                ? normSpec.sublist(0, 256)
                : normSpec;
            peak = limited.isEmpty ? 0.0 : limited.reduce(max);
            _logBands = null; // не используем
          }
        } else if (_decayBetweenUpdates && _prevSpectrum != null) {
          final decayed = List<double>.from(_prevSpectrum!);
          for (int i = 0; i < decayed.length; i++) {
            decayed[i] = (decayed[i] * _decayFactor).clamp(0.0, 1.0);
          }
          _prevSpectrum = decayed;
          limited = decayed.length > 256 ? decayed.sublist(0, 256) : decayed;
          peak = limited.isEmpty ? 0.0 : limited.reduce(max);
        }

        if (limited != null) {
          setState(() {
            _fft = limited!;
            _peak = peak;
          });
        }

        // FPS логирование по времени, а не по количеству кадров
        _frameCount++;
        framesSinceLastLog++;
        final nowStamp = DateTime.now().millisecondsSinceEpoch;
        if (nowStamp - lastLogStampMs >= _logEveryMs) {
          final fps = (framesSinceLastLog * 1000) / (nowStamp - lastLogStampMs);
          final bins = _useLogBands ? (_logBands?.length ?? 0) : _fft.length;
          lastLogStampMs = nowStamp;
          framesSinceLastLog = 0;
          _log(
            'Frame=$_frameCount fps=${fps.toStringAsFixed(1)} mode=${_useFft ? 'FFT' : 'WAVE'} '
            'decay=$_decayBetweenUpdates ws=$_windowSamples upd=${_updateIntervalMs} full=${_fullComputeIntervalMs} '
            'pos=${pos.toStringAsFixed(2)}s bins=$bins peak=${_peak.toStringAsFixed(3)}',
          );
        }
      } catch (e) {
        _log('FFT frame error', e is Exception ? e : Exception(e));
      } finally {
        busy = false;
      }
    });
  }

  void _togglePlayPause() {
    if (_isPlaying) {
      _player.pause();
    } else {
      _player.resume();
    }
    setState(() => _isPlaying = !_isPlaying);
  }

  // Изолятная функция FFT: получает Float32List исходных PCM сэмплов, применяет Hann и FFT.
  // Выносим вычисления с учётом что compute передаст копию списка.
  // Помечаем @pragma для надёжного доступа при tree-shake.
  @pragma('vm:entry-point')
  static List<double> _computeSpectrumIsolate(Float32List samples) {
    final n = samples.length;
    // Применяем Hann окно
    final windowed = Float32List(n);
    for (int i = 0; i < n; i++) {
      final w = 0.5 * (1 - cos(2 * pi * i / (n - 1)));
      windowed[i] = samples[i] * w;
    }
    // FFT radix-2
    int m = 1;
    while (m < n) {
      m <<=
          1; // гарантируем степень двойки (n уже должен быть степенью, иначе паддинг)
    }
    final size = m;
    final real = Float32List(size);
    final imag = Float32List(size);
    if (size == n) {
      for (int i = 0; i < n; i++) {
        real[i] = windowed[i];
      }
    } else {
      // паддинг нулями
      for (int i = 0; i < n; i++) {
        real[i] = windowed[i];
      }
      for (int i = n; i < size; i++) {
        real[i] = 0.0;
      }
    }

    // битовое развёртывание
    int j = 0;
    for (int i = 0; i < size; i++) {
      if (i < j) {
        final tmp = real[i];
        real[i] = real[j];
        real[j] = tmp;
      }
      int bit = size >> 1;
      while (j & bit != 0) {
        j &= ~bit;
        bit >>= 1;
      }
      j |= bit;
    }

    for (int len = 2; len <= size; len <<= 1) {
      final halfLen = len >> 1;
      final theta = -2 * pi / len;
      final wLenCos = cos(theta);
      final wLenSin = sin(theta);
      double wCos = 1.0;
      double wSin = 0.0;
      for (int k = 0; k < halfLen; k++) {
        for (int i = k; i < size; i += len) {
          final j2 = i + halfLen;
          final tReal = wCos * real[j2] - wSin * imag[j2];
          final tImag = wCos * imag[j2] + wSin * real[j2];
          real[j2] = real[i] - tReal;
          imag[j2] = imag[i] - tImag;
          real[i] += tReal;
          imag[i] += tImag;
        }
        final tmpCos = wCos * wLenCos - wSin * wLenSin;
        wSin = wCos * wLenSin + wSin * wLenCos;
        wCos = tmpCos;
      }
    }

    final magnitudes = List<double>.filled(size >> 1, 0.0);
    for (int i = 0; i < (size >> 1); i++) {
      final re = real[i];
      final im = imag[i];
      magnitudes[i] = sqrt(re * re + im * im) / (size / 2);
    }
    return magnitudes;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _heartbeatTimer?.cancel();
    _posSub?.cancel();
    // Останавливаем плеер и чистим PCM ресурсы
    // ignore: discarded_futures
    _player.dispose();
    // ignore: discarded_futures
    _pcmRepo?.dispose();
    _log('Disposed visualizer state');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MP3 Spectrum (audioplayers + FFmpeg)')),
      body: Column(
        children: [
          Expanded(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _useLogBands
                    ? LogSpectrumPainter(
                        bands: _logBands ?? const [],
                        peakHolds: _peakHold,
                      )
                    : SpectrumPainter(_fft, peak: _peak),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          _buildControls(),
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _togglePlayPause,
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                  label: Text(_isPlaying ? 'Пауза' : 'Играть'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: () async {
                    await _player.stop();
                    await _player.play(AssetSource('audio/sample.mp3'));
                  },
                  icon: const Icon(Icons.replay),
                  label: const Text('Restart'),
                ),
              ],
            ),
          ),
          if (_decodeReady)
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                _decodeInfo,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Switch(
                value: _visualizationMasterEnabled,
                onChanged: (v) {
                  setState(() => _visualizationMasterEnabled = v);
                  _log('Master visualization=${v ? 'ON' : 'OFF'}');
                  if (v) {
                    _restartTimer();
                  } else {
                    _timer?.cancel();
                  }
                },
              ),
              const Text('Vis'),
              const SizedBox(width: 12),
              Switch(
                value: _useFft,
                onChanged: (v) {
                  setState(() => _useFft = v);
                  _log('Mode switched to ${v ? 'FFT' : 'WAVE'}');
                },
              ),
              Text(_useFft ? 'FFT режим' : 'Wave режим'),
              const SizedBox(width: 16),
              Switch(
                value: _decayBetweenUpdates,
                onChanged: (v) {
                  setState(() => _decayBetweenUpdates = v);
                  _log('Decay switched to $v');
                },
              ),
              const Text('Decay'),
            ],
          ),
          Row(
            children: [
              const Text('Окно:'),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _windowSamples,
                items: const [256, 512, 1024]
                    .map((e) => DropdownMenuItem(value: e, child: Text('$e')))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _windowSamples = v);
                  _log('Window size set to $v');
                },
              ),
              const SizedBox(width: 16),
              const Text('Bands:'),
              Switch(
                value: _useLogBands,
                onChanged: (v) {
                  setState(() => _useLogBands = v);
                  _log('Log bands=${v ? 'ON' : 'OFF'}');
                },
              ),
              const SizedBox(width: 8),
              const Text('ISO'),
              Switch(
                value: _useIsoBands,
                onChanged: (v) {
                  setState(() => _useIsoBands = v);
                  _log('ISO bands=${v ? 'ON' : 'OFF'}');
                },
              ),
              const SizedBox(width: 8),
              const Text('Интервал отрисовки:'),
              Expanded(
                child: Slider(
                  min: 20,
                  max: 150,
                  divisions: 13,
                  label: '$_updateIntervalMs ms',
                  value: _updateIntervalMs.toDouble(),
                  onChanged: (val) {
                    setState(() => _updateIntervalMs = val.round());
                  },
                  onChangeEnd: (_) {
                    _log('Update interval set to $_updateIntervalMs ms');
                    _restartTimer();
                  },
                ),
              ),
            ],
          ),
          Row(
            children: [
              const Text('Полный пересчёт:'),
              Expanded(
                child: Slider(
                  min: 150,
                  max: 1000,
                  divisions: 17,
                  label: '$_fullComputeIntervalMs ms',
                  value: _fullComputeIntervalMs.toDouble(),
                  onChanged: (val) {
                    setState(() => _fullComputeIntervalMs = val.round());
                  },
                  onChangeEnd: (_) => _log(
                    'Full compute interval set to $_fullComputeIntervalMs ms',
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              const Text('EMA α:'),
              Expanded(
                child: Slider(
                  min: 0.1,
                  max: 0.9,
                  divisions: 8,
                  label: _emaAlpha.toStringAsFixed(2),
                  value: _emaAlpha,
                  onChanged: (v) {
                    setState(() => _emaAlpha = v);
                    _log('EMA alpha set to ${_emaAlpha.toStringAsFixed(2)}');
                  },
                ),
              ),
              const SizedBox(width: 16),
              const Text('Decay:'),
              Expanded(
                child: Slider(
                  min: 0.90,
                  max: 0.995,
                  divisions: 19,
                  label: _decayFactor.toStringAsFixed(3),
                  value: _decayFactor,
                  onChanged: (v) {
                    setState(() => _decayFactor = v);
                    _log(
                      'Decay factor set to ${_decayFactor.toStringAsFixed(3)}',
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _restartTimer() {
    _timer?.cancel();
    if (_visualizationMasterEnabled) {
      _startFftPolling();
    }
  }

  // --- Логарифмическое отображение спектра ---
  static const List<double> _isoCenters = [
    20,
    25,
    31.5,
    40,
    50,
    63,
    80,
    100,
    125,
    160,
    200,
    250,
    315,
    400,
    500,
    630,
    800,
    1000,
    1250,
    1600,
    2000,
    2500,
    3150,
    4000,
    5000,
    6300,
    8000,
    10000,
    12500,
    16000,
    20000,
  ];

  void _ensurePeakHoldLength(int n) {
    if (_peakHold.length == n) return;
    if (_peakHold.length < n) {
      _peakHold += List<double>.filled(n - _peakHold.length, 0.0);
    } else {
      _peakHold = _peakHold.sublist(0, n);
    }
  }

  List<double> _mapFftToLogBands({
    required List<double> magnitudes,
    required int sampleRate,
    required int bands,
    List<double>? prevBands,
    double emaAlpha = 0.7,
    double minFreq = 20,
    double maxFreq = 20000,
  }) {
    if (magnitudes.isEmpty) return List.filled(bands, 0);
    final nyquist = sampleRate / 2.0;
    final usableMax = min(maxFreq, nyquist);
    final logMin = log(minFreq);
    final logMax = log(usableMax);

    // Power (magnitude^2)
    final power = List<double>.generate(magnitudes.length, (i) {
      final m = magnitudes[i];
      return m * m;
    }, growable: false);

    final out = List<double>.filled(bands, 0);
    for (int b = 0; b < bands; b++) {
      final t0 = b / bands;
      final t1 = (b + 1) / bands;
      final f0 = exp(logMin + (logMax - logMin) * t0);
      final f1 = exp(logMin + (logMax - logMin) * t1);
      final bin0 = ((f0 / nyquist) * (magnitudes.length - 1)).floor();
      final bin1 = ((f1 / nyquist) * (magnitudes.length - 1)).ceil();
      if (bin1 <= bin0) {
        out[b] = 0;
        continue;
      }
      double sum = 0;
      int count = 0;
      for (int i = bin0; i <= bin1 && i < power.length; i++) {
        sum += power[i];
        count++;
      }
      final avgPower = count > 0 ? sum / count : 0.0;
      const eps = 1e-12;
      final db = 10 * log(avgPower + eps) / ln10; // convert to dB
      final norm = ((db + 60) / 60).clamp(0.0, 1.0); // -60..0 dB -> 0..1
      if (prevBands != null && prevBands.length == bands) {
        out[b] = prevBands[b] * emaAlpha + norm * (1 - emaAlpha);
      } else {
        out[b] = norm;
      }
    }
    return out;
  }

  // ISO 1/3-octave bands mapping using geometric edges around centers
  List<double> _mapFftToIsoBands({
    required List<double> magnitudes,
    required int sampleRate,
    List<double>? prevBands,
    double emaAlpha = 0.7,
  }) {
    if (magnitudes.isEmpty) return const [];
    final nyquist = sampleRate / 2.0;
    // Build edges as geometric mean between adjacent centers; clamp to [20, nyquist]
    final centers = _isoCenters.where((f) => f < nyquist).toList();
    if (centers.isEmpty) return const [];
    final edges = <double>[];
    edges.add(
      max(20.0, centers.first / pow(2, 1 / 6)),
    ); // half-band below first center
    for (int i = 0; i < centers.length - 1; i++) {
      final e = sqrt(centers[i] * centers[i + 1]);
      edges.add(e);
    }
    edges.add(
      min(20000.0, centers.last * pow(2, 1 / 6)),
    ); // half-band above last center

    // Power spectrum
    final power = List<double>.generate(magnitudes.length, (i) {
      final m = magnitudes[i];
      return m * m;
    }, growable: false);

    final out = List<double>.filled(centers.length, 0.0);
    for (int b = 0; b < centers.length; b++) {
      final f0 = edges[b];
      final f1 = b + 1 < edges.length ? edges[b + 1] : edges[b] * pow(2, 1 / 3);
      final f0c = f0.clamp(20.0, nyquist);
      final f1c = f1.clamp(20.0, nyquist);
      if (f1c <= f0c) {
        out[b] = 0;
        continue;
      }
      final bin0 = ((f0c / nyquist) * (magnitudes.length - 1)).floor();
      final bin1 = ((f1c / nyquist) * (magnitudes.length - 1)).ceil();
      double sum = 0;
      int count = 0;
      for (int i = bin0; i <= bin1 && i < power.length; i++) {
        sum += power[i];
        count++;
      }
      final avgPower = count > 0 ? sum / max(1, count) : 0.0;
      const eps = 1e-12;
      final db = 10 * log(avgPower + eps) / ln10; // dBFS approx
      final norm = ((db + 60) / 60).clamp(0.0, 1.0); // -60..0 dB -> 0..1
      if (prevBands != null && prevBands.length == centers.length) {
        out[b] = prevBands[b] * emaAlpha + norm * (1 - emaAlpha);
      } else {
        out[b] = norm;
      }
    }
    return out;
  }

  // Простая энергетическая визуализация без FFT: разбиваем на полосы и берём среднее abs.
  List<double> _waveFallback(Float32List samples) {
    const bands = 256;
    final slice = samples;
    final perBand = max(1, slice.length ~/ bands);
    final out = List<double>.filled(bands, 0.0);
    for (int b = 0; b < bands; b++) {
      final start = b * perBand;
      final end = min(slice.length, start + perBand);
      double sum = 0;
      for (int i = start; i < end; i++) {
        sum += slice[i].abs();
      }
      final avg = end > start ? sum / (end - start) : 0.0;
      // Лог-компрессия
      out[b] = log(1 + avg * 20) / log(21);
    }
    return out;
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      _player.getCurrentPosition().then((pos) {
        final ms = pos?.inMilliseconds ?? -1;
        _log(
          'HEARTBEAT t=${DateTime.now().millisecondsSinceEpoch} posMs=${ms} vis=${_visualizationMasterEnabled} fft=${_useFft}',
        );
      });
    });
  }
}

class SpectrumPainter extends CustomPainter {
  final List<double> fft;
  final double peak;
  SpectrumPainter(this.fft, {required this.peak});

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = Colors.black;
    canvas.drawRect(Offset.zero & size, bg);

    if (fft.isEmpty) {
      final tp = TextPainter(
        text: const TextSpan(
          text: 'Ожидание FFT...',
          style: TextStyle(color: Colors.white70),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, const Offset(16, 16));
      return;
    }

    final n = fft.length;
    final barWidth = max(1.0, size.width / n);
    final paint = Paint()..style = PaintingStyle.fill;
    for (int i = 0; i < n; i++) {
      final v = fft[i].clamp(0.0, 1.0);
      final barHeight = v * size.height * 0.9;
      final x = i * barWidth;
      final rect = Rect.fromLTWH(
        x,
        size.height - barHeight,
        barWidth * 0.9,
        barHeight,
      );
      paint.color =
          Color.lerp(Colors.blueGrey, Colors.cyanAccent, v) ??
          Colors.cyanAccent;
      canvas.drawRect(rect, paint);
    }

    // Линия пика
    final yPeak = size.height - (peak.clamp(0.0, 1.0) * size.height * 0.9);
    final peakPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.orangeAccent;
    canvas.drawLine(Offset(0, yPeak), Offset(size.width, yPeak), peakPaint);
  }

  @override
  bool shouldRepaint(covariant SpectrumPainter oldDelegate) =>
      !listEquals(oldDelegate.fft, fft) || oldDelegate.peak != peak;
}

// Painter для логарифмических полос с peak hold.
class LogSpectrumPainter extends CustomPainter {
  final List<double> bands;
  final List<double> peakHolds;
  final Paint _peakPaint = Paint()
    ..color = Colors.orangeAccent
    ..strokeWidth = 2;

  LogSpectrumPainter({required this.bands, required this.peakHolds});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    if (bands.isEmpty) {
      final tp = TextPainter(
        text: const TextSpan(
          text: 'Ожидание спектра...',
          style: TextStyle(color: Colors.white54),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, const Offset(12, 12));
      return;
    }
    final n = bands.length;
    final barW = size.width / max(1, n);
    final barPaint = Paint()..style = PaintingStyle.fill;
    for (int i = 0; i < n; i++) {
      final v = bands[i].clamp(0.0, 1.0);
      final h = v * size.height * 0.92;
      final x = i * barW;
      final rect = Rect.fromLTWH(x, size.height - h, barW * 0.9, h);
      barPaint.color =
          Color.lerp(Colors.blueGrey, Colors.cyanAccent, v) ??
          Colors.cyanAccent;
      canvas.drawRect(rect, barPaint);

      // Peak hold line
      final peak = peakHolds[i].clamp(0.0, 1.0);
      final peakY = size.height - peak * size.height * 0.92;
      canvas.drawLine(
        Offset(x, peakY),
        Offset(x + barW * 0.9, peakY),
        _peakPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant LogSpectrumPainter oldDelegate) =>
      !listEquals(oldDelegate.bands, bands) ||
      !listEquals(oldDelegate.peakHolds, peakHolds);
}
