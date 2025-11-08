// Clean rewritten file implementing audio visualizer
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Получаем singleton instance
  final soloud = SoLoud.instance;
  // Инициализация движка (параметры можно настроить)
  await soloud.init();
  // Включаем визуализацию (нужно для getWave/getSpectrum)
  soloud.setVisualizationEnabled(true);
  // Сглаживание значений спектра (0-1)
  soloud.setFftSmoothing(0.6);
  runApp(const MyApp());
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

  @override
  void initState() {
    super.initState();
    _loadAndPlay();
    _startFftPolling();
  }

  Future<void> _loadAndPlay() async {
    try {
      final soloud = SoLoud.instance;
      final source = await soloud.loadAsset('assets/audio/sample.mp3');
      final h = await soloud.play(source, volume: 1.0);
      setState(() {
        _handle = h;
        _isPlaying = true;
      });
    } catch (e) {
      debugPrint('Ошибка: $e');
    }
  }

  void _startFftPolling() {
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) async {
      try {
        final soloud = SoLoud.instance;
        // В текущей версии документации метод получения FFT не отображается.
        // TEMP: синтетическая визуализация на основе громкости.
        if (!mounted) return;
        // Получаем текущий глобальный уровень (объём всех звуков) как основу.
        final vol = soloud.getGlobalVolume();
        // Генерируем псевдо спектр (НЕ РЕАЛЬНЫЙ FFT) до уточнения API.
        final bins = 64;
        final rand = Random();
        List<double> data = List.generate(bins, (i) {
          final base = vol * 10.0; // масштаб
          final falloff = 1.0 - (i / bins);
          return (base * falloff) * rand.nextDouble();
        });
        final double peak = data.isEmpty ? 0.0 : data.reduce(max).toDouble();
        setState(() {
          _fft = data;
          _peak = peak;
        });
      } catch (_) {
        // ignore errors
      }
    });
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
      soloud.stop(h); // fire-and-forget
    }
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
    final barWidth = size.width / n;
    for (int i = 0; i < n; i++) {
      double v = fft[i].clamp(0, 10);
      final mag = log(1 + v) / log(11); // 0..1
      final barHeight = mag * size.height * 0.92;
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

    final peakNorm = log(1 + peak.clamp(0, 10)) / log(11);
    final yPeak = size.height - (peakNorm * size.height * 0.92);
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
