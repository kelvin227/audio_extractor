import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: AudioExtractorPage(),
  ));
}

class AudioExtractorPage extends StatefulWidget {
  const AudioExtractorPage({super.key});

  @override
  State<AudioExtractorPage> createState() => _AudioExtractorPageState();
}

class _AudioExtractorPageState extends State<AudioExtractorPage> {
  String? _videoPath;
  double _durationSeconds = 0.0;
  double _startSeconds = 0.0;
  double _endSeconds = 0.0;
  bool _isProcessing = false;
  double _progress = 0.0; // 0..1
  String _status = "";
  String? _extractedAudioPath;
  final AudioPlayer _player = AudioPlayer();
  final TextEditingController _filenameController = TextEditingController();
  bool _useMp3 = true; // toggle between AAC (copy) or MP3 (re-encode)

  /// ---- PICK VIDEO ----
  Future<void> _pickVideo() async {
    try {
      FilePickerResult? res =
      await FilePicker.platform.pickFiles(type: FileType.video);
      if (res == null) return;
      final path = res.files.single.path;
      if (path == null) return;
      setState(() {
        _videoPath = path;
        _status = "Loading video info...";
        _progress = 0.0;
        _extractedAudioPath = null;
      });
      await _getVideoDuration(path);
    } catch (e) {
      setState(() => _status = "Failed to pick video: $e");
    }
  }

  /// ---- GET VIDEO DURATION USING FFMPEG ----
  Future<void> _getVideoDuration(String path) async {
    try {
      final result = await Process.run(
          'ffprobe',
          [
            '-v',
            'error',
            '-show_entries',
            'format=duration',
            '-of',
            'default=noprint_wrappers=1:nokey=1',
            path
          ],
          runInShell: true);
      if (result.exitCode == 0) {
        double dur = double.tryParse(result.stdout.toString().trim()) ?? 0.0;
        setState(() {
          _durationSeconds = dur;
          _startSeconds = 0.0;
          _endSeconds = dur;
          _status = "Ready — duration: ${_formatDurationSeconds(dur)}";
        });
      } else {
        setState(() => _status = "Failed to get duration: ${result.stderr}");
      }
    } catch (e) {
      setState(() => _status = "Error getting duration: $e");
    }
  }

  /// ---- EXTRACT AUDIO USING FFMPEG ----
  Future<void> _trimAndExtract() async {
    if (_videoPath == null) {
      setState(() => _status = "No video selected");
      return;
    }

    String filename = _filenameController.text.trim();
    if (filename.isEmpty) {
      filename = "audio_${DateTime.now().millisecondsSinceEpoch}";
    }

    final docs = await getApplicationDocumentsDirectory();
    final ext = _useMp3 ? 'mp3' : 'aac';
    final outputPath = "${docs.path}/$filename.$ext";

    final start = _startSeconds.toStringAsFixed(3);
    final end = _endSeconds.toStringAsFixed(3);

    setState(() {
      _isProcessing = true;
      _progress = 0.0;
      _status =
      "Extracting audio (${_formatDurationSeconds(_endSeconds - _startSeconds)})...";
      _extractedAudioPath = null;
    });

    try {
      final ffmpegPath = 'ffmpeg'; // or full path: r'C:\ffmpeg\bin\ffmpeg.exe'
      final args = [
        '-y',
        '-i',
        _videoPath!,
        '-ss',
        start,
        '-to',
        end,
        '-vn',
      ];

      if (_useMp3) {
        args.addAll(['-acodec', 'libmp3lame', '-q:a', '2']); // MP3 re-encode
      } else {
        args.addAll(['-acodec', 'copy']); // AAC copy
      }

      args.add(outputPath);

      final process = await Process.start(ffmpegPath, args, runInShell: true);

      process.stderr.transform(SystemEncoding().decoder).listen((line) {
        final regex = RegExp(r'time=(\d+):(\d+):(\d+\.?\d*)');
        final match = regex.firstMatch(line);
        if (match != null) {
          final h = double.parse(match.group(1)!);
          final m = double.parse(match.group(2)!);
          final s = double.parse(match.group(3)!);
          final processedSec = h * 3600 + m * 60 + s;
          double denom = _endSeconds - _startSeconds;
          if (denom <= 0) denom = 1.0;
          double frac = ((processedSec - _startSeconds) / denom).clamp(0.0, 1.0);
          setState(() {
            _progress = frac;
          });
        }
      });

      final exitCode = await process.exitCode;
      if (exitCode == 0) {
        setState(() {
          _status = "Audio saved: $outputPath";
          _extractedAudioPath = outputPath;
          _progress = 1.0;
        });
      } else {
        setState(() {
          _status = "FFmpeg failed with code $exitCode";
          _progress = 0.0;
          _extractedAudioPath = null;
        });
      }
    } catch (e) {
      setState(() {
        _status = "Extraction error: $e";
        _progress = 0.0;
        _extractedAudioPath = null;
      });
    }

    setState(() => _isProcessing = false);
  }

  String _formatDurationSeconds(double s) {
    final total = s.round();
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    if (hours > 0) {
      return "${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}";
    } else {
      return "${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}";
    }
  }

  Future<void> _playExtracted() async {
    if (_extractedAudioPath == null) return;
    try {
      await _player.setFilePath(_extractedAudioPath!);
      _player.play();
    } catch (e) {
      setState(() => _status = "Play error: $e");
    }
  }

  @override
  void dispose() {
    _player.dispose();
    _filenameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalDuration = _durationSeconds;
    final trimmedDuration = (_endSeconds - _startSeconds).clamp(0.0, totalDuration);
    return Scaffold(
      appBar: AppBar(title: const Text("Audio Extractor (Desktop)")),
      body: Padding(
        padding: const EdgeInsets.all(18.0),
        child: Column(
          children: [
            ElevatedButton.icon(
              onPressed: _isProcessing ? null : _pickVideo,
              icon: const Icon(Icons.video_library),
              label: const Text("Pick Video"),
            ),
            const SizedBox(height: 12),
            Text(_videoPath ?? "No video selected"),
            const SizedBox(height: 8),
            if (totalDuration > 0) ...[
              Text("Duration: ${_formatDurationSeconds(totalDuration)}"),
              const SizedBox(height: 12),
              Text(
                  "Trim range: ${_formatDurationSeconds(_startSeconds)} — ${_formatDurationSeconds(_endSeconds)}"),
              RangeSlider(
                min: 0,
                max: totalDuration,
                values: RangeValues(_startSeconds, _endSeconds),
                onChanged: _isProcessing
                    ? null
                    : (values) {
                  setState(() {
                    _startSeconds = values.start.clamp(0.0, totalDuration);
                    _endSeconds = values.end.clamp(0.0, totalDuration);
                    if (_endSeconds <= _startSeconds) {
                      _endSeconds =
                          (_startSeconds + 0.5).clamp(0.0, totalDuration);
                    }
                  });
                },
              ),
              const SizedBox(height: 8),
              Text("Trimmed length: ${_formatDurationSeconds(trimmedDuration)}"),
              const SizedBox(height: 12),
              TextField(
                controller: _filenameController,
                decoration: const InputDecoration(
                  labelText: "Output filename (no extension)",
                  border: OutlineInputBorder(),
                ),
              ),
              Row(
                children: [
                  Checkbox(
                      value: _useMp3,
                      onChanged: (v) {
                        setState(() {
                          _useMp3 = v ?? true;
                        });
                      }),
                  const Text("Export as MP3 (re-encode)"),
                ],
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed:
                (_isProcessing || totalDuration <= 0) ? null : _trimAndExtract,
                icon: const Icon(Icons.cut),
                label: const Text("Extract Trimmed Audio"),
              ),
            ],
            const SizedBox(height: 18),
            if (_isProcessing) ...[
              Text(_status),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _progress),
            ] else ...[
              Text(_status),
            ],
            const SizedBox(height: 18),
            if (_extractedAudioPath != null) ...[
              Text("Saved: $_extractedAudioPath"),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: _playExtracted,
                icon: const Icon(Icons.play_arrow),
                label: const Text("Play"),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
