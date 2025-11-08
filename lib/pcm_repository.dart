import 'dart:async';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

class PcmRepository {
  PcmRepository({
    required this.assetPath,
    required this.stereo,
    this.sampleRate = 44100,
  });

  final String assetPath;
  final bool stereo;
  final int sampleRate;

  late final io.Directory _tmpDir;
  late final String _mp3Path;
  late final String _pcmPath;
  io.RandomAccessFile? _raf;
  int channels = 1;
  int totalFrames = 0;

  Future<void> ensureReady() async {
    channels = stereo ? 2 : 1;
    _tmpDir = await io.Directory.systemTemp.createTemp('music_visio_pcm_');
    _mp3Path = io.File('${_tmpDir.path}/input.mp3').path;
    _pcmPath = io.File(
      '${_tmpDir.path}/audio_${sampleRate}_${channels}ch_f32le.pcm',
    ).path;

    // Write asset mp3 to temp if not exists
    final mp3File = io.File(_mp3Path);
    if (!mp3File.existsSync()) {
      final data = await rootBundle.load(assetPath);
      await mp3File.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }

    final pcmFile = io.File(_pcmPath);
    if (!pcmFile.existsSync()) {
      // Use external ffmpeg (must be installed and available in PATH)
      final ffmpegCheck = await io.Process.run('ffmpeg', [
        '-hide_banner',
        '-version',
      ]);
      if (ffmpegCheck.exitCode != 0) {
        throw Exception(
          'FFmpeg executable not found in PATH.\n'
          'Install FFmpeg and add it to PATH.\n'
          'Windows tip: download from https://www.gyan.dev/ffmpeg/builds/ (release full), unzip, and add the bin folder to PATH.',
        );
      }
      final args = <String>[
        '-y',
        '-i',
        _mp3Path,
        '-f',
        'f32le',
        '-acodec',
        'pcm_f32le',
        '-ac',
        channels.toString(),
        '-ar',
        sampleRate.toString(),
        _pcmPath,
      ];
      final result = await io.Process.run('ffmpeg', args);
      if (result.exitCode != 0) {
        throw Exception(
          'ffmpeg decode failed (exitCode=${result.exitCode})\nSTDERR:${result.stderr}\nSTDOUT:${result.stdout}',
        );
      }
    }

    // Open for random reads
    _raf = await io.File(_pcmPath).open(mode: io.FileMode.read);
    final bytes = await _raf!.length();
    final bytesPerFrame = 4 * channels; // float32 * channels
    totalFrames = bytes ~/ bytesPerFrame;
  }

  Future<Float32List> readMonoWindow(
    int endFrameExclusive,
    int windowFrames,
  ) async {
    if (_raf == null) return Float32List(0);
    final startFrame = max(0, endFrameExclusive - windowFrames);
    final framesToRead = min(windowFrames, endFrameExclusive - startFrame);
    if (framesToRead <= 0) return Float32List(0);

    final bytesPerFrame = 4 * channels;
    final startOffset = startFrame * bytesPerFrame;
    final bytesToRead = framesToRead * bytesPerFrame;

    await _raf!.setPosition(startOffset);

    final buffer = Uint8List(bytesToRead);
    int offset = 0;
    while (offset < bytesToRead) {
      final chunk = await _raf!.read(bytesToRead - offset);
      if (chunk.isEmpty) break;
      buffer.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }

    final floatView = buffer.buffer.asFloat32List();
    final out = Float32List(framesToRead);
    if (channels == 1) {
      out.setAll(0, floatView);
    } else {
      // stereo -> mono
      for (int i = 0, o = 0; i < floatView.length; i += 2, o++) {
        final l = floatView[i];
        final r = (i + 1) < floatView.length ? floatView[i + 1] : 0.0;
        out[o] = (l + r) * 0.5;
      }
    }

    // If framesToRead < windowFrames (at start), pad left with zeros
    if (framesToRead < windowFrames) {
      final padded = Float32List(windowFrames);
      final pad = windowFrames - framesToRead;
      // zeros at beginning
      padded.setRange(pad, windowFrames, out);
      return padded;
    }
    return out;
  }

  Future<void> dispose() async {
    try {
      await _raf?.close();
      if (_tmpDir.existsSync()) {
        await _tmpDir.delete(recursive: true);
      }
    } catch (_) {}
  }
}
