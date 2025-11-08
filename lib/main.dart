// Clean rewritten file implementing audio visualizer
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:io' as io;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show rootBundle; // для загрузки asset как bytes
import 'package:flutter_soloud/flutter_soloud.dart';

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

      _log('Initializing SoLoud...');
      final soloud = SoLoud.instance;
      try {
        await soloud.init();
        _log('SoLoud initialized (isInitialized=${soloud.isInitialized})');
      } catch (e, st) {
        _log('SoLoud init failed', e, st);
      }
      soloud.setVisualizationEnabled(true);
      soloud.setFftSmoothing(0.6);
      _log('Visualization enabled=${soloud.getVisualizationEnabled()}');
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
  SoundHandle? _handle;
  List<double> _fft = const [];
  Timer? _timer;
  bool _isPlaying = false;
  double _peak = 0;
  Uint8List? _assetBuffer; // кешированное содержимое mp3 для чтения сэмплов
  List<double>? _prevSpectrum; // для сглаживания между кадрами
  int _frameCount = 0; // счетчик кадров для условного логирования
  String? _tmpFilePath; // путь к временному mp3 (для readSamplesFromFile)
  io.Directory? _tmpDir; // чтобы удалить позже

  @override
  void initState() {
    super.initState();
    _loadAndPlay();
    _startFftPolling();
  }

  Future<void> _loadAndPlay() async {
    try {
      final soloud = SoLoud.instance;

      // Загружаем asset как bytes, чтобы затем использовать readSamplesFromMem
      final assetPath = 'assets/audio/sample.mp3';
      _log('Loading asset bytes: $assetPath');
      final byteData = await rootBundle.load(assetPath);
      _assetBuffer = byteData.buffer.asUint8List();
      _log('Asset bytes loaded length=${_assetBuffer!.length}');

      // Пишем байты в временный файл, чтобы не копировать весь буфер в изолят каждые 60 мс
      _tmpDir = await io.Directory.systemTemp.createTemp('music_visio_');
      final file = io.File('${_tmpDir!.path}/sample.mp3');
      await file.writeAsBytes(_assetBuffer!, flush: false);
      _tmpFilePath = file.path;
      _log('Temp file created at $_tmpFilePath');

      // Загружаем звук из файла (меньше нагрузки на память)
      final source = await soloud.loadFile(
        _tmpFilePath!,
        mode: LoadMode.memory,
      );
      _log(
        'AudioSource loaded (hash=${source.soundHash.hash}). Starting playback...',
      );
      final h = await soloud.play(source, volume: 1.0);
      _log('Playback started (handle=${h.id})');
      setState(() {
        _handle = h;
        _isPlaying = true;
      });
    } catch (e) {
      _log('Loading/playback failed', e is Exception ? e : Exception(e));
    }
  }

  void _startFftPolling() {
    const frameInterval = Duration(milliseconds: 50); // ~20 FPS отрисовки
    const windowSamples = 512; // меньше окно -> ниже нагрузка
    // Максимум частоты спектра = sampleRate/2. Предполагаем 44100.
    const sampleRate = 44100.0;
    const smoothing =
        0.6; // доп. сглаживание между кадрами (не путать с setFftSmoothing)

    bool busy = false;
    DateTime lastCompute = DateTime.fromMillisecondsSinceEpoch(0);
    _timer = Timer.periodic(frameInterval, (_) async {
      if (busy) return;
      busy = true;
      if (!mounted) return;
      final h = _handle;
      final path = _tmpFilePath;
      if (h == null || path == null) {
        busy = false;
        return; // ещё не готовы
      }
      final soloud = SoLoud.instance;
      try {
        // Текущее положение воспроизведения
        final pos = soloud.getPosition(h).inMilliseconds / 1000.0;
        if (pos <= 0) {
          busy = false;
          return;
        }
        // Обновляем спектр не чаще, чем раз в 250 мс, чтобы не плодить изолятов
        final now = DateTime.now();
        List<double>? limited;
        double peak = 0.0;
        if (now.difference(lastCompute).inMilliseconds >= 250) {
          lastCompute = now;

          final windowDuration = windowSamples / sampleRate; // ~11.6ms
          final startTime = max(0.0, pos - windowDuration);
          final endTime = pos; // читаем до текущего времени

          // Читаем равномерно распределённые сэмплы по времени из файла
          final samples = await soloud.readSamplesFromFile(
            path,
            windowSamples,
            startTime: startTime,
            endTime: endTime,
            average: false,
          );

          if (samples.isEmpty) {
            busy = false;
            return;
          }

          // Применяем Hann окно
          final windowed = Float32List(samples.length);
          for (int i = 0; i < samples.length; i++) {
            final w = 0.5 * (1 - cos(2 * pi * i / (samples.length - 1)));
            windowed[i] = samples[i] * w;
          }

          final spectrum = _fftCompute(windowed); // N/2
          final normSpec = List<double>.generate(spectrum.length, (i) {
            final v = spectrum[i];
            return log(1 + v * 50) / log(51); // 0..1 примерно
          });

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
        } else {
          // Между полными пересчётами — плавно затухаем предыдущий спектр
          if (_prevSpectrum != null) {
            final decayed = List<double>.from(_prevSpectrum!);
            for (int i = 0; i < decayed.length; i++) {
              decayed[i] = (decayed[i] * 0.985).clamp(0.0, 1.0);
            }
            _prevSpectrum = decayed;
            limited = decayed.length > 256 ? decayed.sublist(0, 256) : decayed;
            peak = limited.isEmpty ? 0.0 : limited.reduce(max);
          }
        }

        if (!mounted) {
          busy = false;
          return;
        }
        if (limited != null) {
          setState(() {
            _fft = limited!;
            _peak = peak;
          });
        }

        // Логируем каждые 30 кадров чтобы не засорять вывод
        if (++_frameCount % 30 == 0) {
          _log(
            'Frame=$_frameCount pos=${pos.toStringAsFixed(2)}s bins=${_fft.length} peak=${_peak.toStringAsFixed(3)}',
          );
        }
      } catch (e) {
        _log('FFT frame error', e is Exception ? e : Exception(e));
      } finally {
        busy = false;
      }
    });
  }

  // Быстрая реализация FFT (Cooley–Tukey, radix-2, только magnitudes) над real сигналом.
  // Возвращает список длиной N/2 с мощностями спектра.
  List<double> _fftCompute(Float32List input) {
    final n = input.length;
    // Убедимся что n — степень двойки
    if ((n & (n - 1)) != 0) {
      // Если нет, дополним нулями до ближайшей степени двойки
      int pow2 = 1;
      while (pow2 < n) pow2 <<= 1;
      final padded = Float32List(pow2);
      padded.setRange(0, n, input);
      return _fftCompute(padded);
    }

    final real = Float32List.fromList(input);
    final imag = Float32List(n);

    // Bit-reversal permutation
    int j = 0;
    for (int i = 0; i < n; i++) {
      if (i < j) {
        final tmpR = real[i];
        real[i] = real[j];
        real[j] = tmpR;
        final tmpI = imag[i];
        imag[i] = imag[j];
        imag[j] = tmpI;
      }
      int m = n >> 1;
      while (j >= m && m > 0) {
        j -= m;
        m >>= 1;
      }
      j += m;
    }

    // FFT stages
    for (int len = 2; len <= n; len <<= 1) {
      final halfLen = len >> 1;
      final theta = -2 * pi / len;
      final wLenCos = cos(theta);
      final wLenSin = sin(theta);
      double wCos = 1.0;
      double wSin = 0.0;
      for (int k = 0; k < halfLen; k++) {
        for (int i = k; i < n; i += len) {
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

    final magnitudes = List<double>.filled(n >> 1, 0.0);
    for (int i = 0; i < (n >> 1); i++) {
      final re = real[i];
      final im = imag[i];
      magnitudes[i] = sqrt(re * re + im * im) / (n / 2); // нормализация
    }
    return magnitudes;
  }

  void _togglePlayPause() {
    final h = _handle;
    if (h == null) return;
    final soloud = SoLoud.instance;
    if (_isPlaying) {
      soloud.setPause(h, true);
    } else {
      soloud.setPause(h, false);
    }
    setState(() => _isPlaying = !_isPlaying);
  }

  @override
  void dispose() {
    _timer?.cancel();
    final h = _handle;
    if (h != null) {
      final soloud = SoLoud.instance;
      // ignore: discarded_futures
      _log('Stopping handle id=${h.id}');
      soloud.stop(h); // fire-and-forget
    }
    // Чистим временные файлы
    try {
      if (_tmpDir != null && _tmpDir!.existsSync()) {
        _log('Deleting temp dir ${_tmpDir!.path}');
        _tmpDir!.deleteSync(recursive: true);
      }
    } catch (e) {
      _log('Temp dir delete failed', e is Exception ? e : Exception(e));
    }
    _log('Disposed visualizer state');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MP3 Spectrum (SoLoud)')),
      body: Column(
        children: [
          Expanded(
            child: CustomPaint(
              painter: SpectrumPainter(_fft, peak: _peak),
              child: const SizedBox.expand(),
            ),
          ),
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
                    final h = _handle;
                    if (h != null) {
                      final soloud = SoLoud.instance;
                      await soloud.stop(h);
                    }
                    await _loadAndPlay();
                  },
                  icon: const Icon(Icons.replay),
                  label: const Text('Restart'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
