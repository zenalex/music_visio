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
  PcmRepository? _pcmRepo;
  bool _decodeReady = false;
  String _decodeInfo = '';
  List<double> _fft = const [];
  Timer? _timer;
  bool _isPlaying = false;
  double _peak = 0;
  List<double>? _prevSpectrum; // для сглаживания между кадрами
  int _frameCount = 0; // счетчик кадров для условного логирования
  // Настройки визуализации
  int _windowSamples = 512;
  int _updateIntervalMs = 60; // таймер перерисовки
  int _fullComputeIntervalMs = 250; // период полного пересчета спектра
  bool _useFft = true; // режим FFT или Wave fallback
  bool _decayBetweenUpdates = true; // затухание между полными апдейтами
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
        final posMs =
            (await _player.getCurrentPosition())?.inMilliseconds.toDouble() ??
            0.0;
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
              normSpec = List<double>.generate(spectrum.length, (i) {
                final v = spectrum[i];
                return log(1 + v * 50) / log(51); // 0..1
              });
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

          limited = normSpec.length > 256 ? normSpec.sublist(0, 256) : normSpec;
          peak = limited.isEmpty ? 0.0 : limited.reduce(max);
        } else if (_decayBetweenUpdates && _prevSpectrum != null) {
          final decayed = List<double>.from(_prevSpectrum!);
          for (int i = 0; i < decayed.length; i++) {
            decayed[i] = (decayed[i] * 0.985).clamp(0.0, 1.0);
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

        if (++_frameCount % 30 == 0) {
          _log(
            'Frame=$_frameCount mode=${_useFft ? 'FFT' : 'WAVE'} decay=$_decayBetweenUpdates ws=$_windowSamples upd=${_updateIntervalMs} full=${_fullComputeIntervalMs} pos=${pos.toStringAsFixed(2)}s bins=${_fft.length} peak=${_peak.toStringAsFixed(3)}',
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
            child: CustomPaint(
              painter: SpectrumPainter(_fft, peak: _peak),
              child: const SizedBox.expand(),
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
      final paint = Paint()
        ..shader = const LinearGradient(
          colors: [Colors.blueAccent, Colors.cyanAccent],
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
        ).createShader(rect);
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
