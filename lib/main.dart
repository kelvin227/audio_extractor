import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/session.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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

  // Pick video file
  Future<void> _pickVideo() async {
    try {
      FilePickerResult? res = await FilePicker.platform.pickFiles(type: FileType.video);
      if (res == null) return;
      final path = res.files.single.path;
      if (path == null) return;
      setState(() {
        _videoPath = path;
        _status = "Probing video...";
        _progress = 0.0;
        _extractedAudioPath = null;
      });
      await _probeDuration(path);
    } catch (e) {
      setState(() => _status = "Failed to pick video: $e");
    }
  }

  // Probe with FFprobe to get duration
  Future<void> _probeDuration(String inputPath) async {
    try {
      final session = await FFprobeKit.getMediaInformation(inputPath);
      final info = session.getMediaInformation();
      final durationStr = info?.getDuration(); // seconds as string
      double dur = 0.0;
      if (durationStr != null) {
        dur = double.tryParse(durationStr) ?? 0.0;
      }
      if (dur <= 0) {
        // fallback: set a default or error
        setState(() {
          _status = "Could not determine duration (FFprobe returned $durationStr)";
          _durationSeconds = 0.0;
          _startSeconds = 0.0;
          _endSeconds = 0.0;
        });
        return;
      }
      setState(() {
        _durationSeconds = dur;
        _startSeconds = 0.0;
        _endSeconds = dur;
        _status = "Ready — duration: ${_formatDurationSeconds(dur)}";
      });
    } catch (e) {
      setState(() => _status = "Probe error: $e");
    }
  }

  // Format seconds -> HH:MM:SS or MM:SS
  String _formatDurationSeconds(double s) {
    final total = s.round();
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    if (hours > 0) {
      return "${hours.toString().padLeft(2,'0')}:${minutes.toString().padLeft(2,'0')}:${seconds.toString().padLeft(2,'0')}";
    } else {
      return "${minutes.toString().padLeft(2,'0')}:${seconds.toString().padLeft(2,'0')}";
    }
  }

  // Extract (with trimming)
  Future<void> _trimAndExtract() async {
    if (_videoPath == null) {
      setState(() => _status = "No video selected");
      return;
    }

    // Get filename input
    String filename = _filenameController.text.trim();
    if (filename.isEmpty) {
      filename = "audio_${DateTime.now().millisecondsSinceEpoch}";
    }

    final docs = await getApplicationDocumentsDirectory();
    final outputPath = "${docs.path}/$filename.mp3";

    final start = _formatSecondsForFFmpeg(_startSeconds);
    final end = _formatSecondsForFFmpeg(_endSeconds);

    // Build FFmpeg command:
    // -y overwrite, -ss start, -to end, -i input, -vn remove video, -acodec libmp3lame
    final command = '-y -i "${_videoPath!}" -ss $start -to $end -vn -acodec libmp3lame "$outputPath"';

    setState(() {
      _isProcessing = true;
      _progress = 0.0;
      _status = "Extracting... (${_formatDurationSeconds(_endSeconds - _startSeconds)})";
      _extractedAudioPath = null;
    });

    // executeAsync with statistics listener to compute progress relative to trimmed segment duration
    await FFmpegKit.executeAsync(
      command,
      (session) async {
        final rc = await session.getReturnCode();
        if (ReturnCode.isSuccess(rc)) {
          setState(() {
            _status = "Saved: $outputPath";
            _extractedAudioPath = outputPath;
            _progress = 1.0;
          });
        } else {
          setState(() {
            _status = "Extraction failed (code: $rc)";
            _extractedAudioPath = null;
            _progress = 0.0;
          });
        }
        setState(() => _isProcessing = false);
      },
      (log) {
        // optional: you can inspect log.getMessage()
        // print("FFmpeg log: ${log.getMessage()}");
      },
      (statistics) {
        // statistics.getTime() returns milliseconds processed so far in the input media.
        // We compute progress as (processed_time - start)/(end - start)
        final timeMs = statistics.getTime().toDouble(); // milliseconds
        // timeMs is relative to input timeline — may be absolute position, so compute relative to startSeconds*1000
        final processedSec = timeMs / 1000.0;
        double denom = (_endSeconds - _startSeconds);
        if (denom <= 0) denom = 1.0;
        // compute fraction: (processedSec - start) / denom
        double frac = (processedSec - _startSeconds) / denom;
        if (frac < 0) frac = 0;
        if (frac > 1) frac = 1;
        setState(() {
          _progress = frac;
        });
      },
    );
  }

  String _formatSecondsForFFmpeg(double seconds) {
    // FFmpeg accepts 'HH:MM:SS' or seconds as float; we'll return seconds with decimals
    // use seconds with 3 decimals for precision
    return seconds.toStringAsFixed(3);
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

  Future<void> _shareExtracted() async {
    if (_extractedAudioPath == null) return;
    await Share.shareXFiles([XFile(_extractedAudioPath!)], text: "Here's the extracted audio");
  }

  @override
  void dispose() {
    _player.dispose();
    _filenameController.dispose();
    super.dispose();
  }

  // UI
  @override
  Widget build(BuildContext context) {
    final totalDuration = _durationSeconds;
    final trimmedDuration = (_endSeconds - _startSeconds).clamp(0.0, totalDuration);
    return Scaffold(
      appBar: AppBar(title: const Text("Audio Extractor (Trim + Extract)")),
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

              // Range selector
              Text("Trim range: ${_formatDurationSeconds(_startSeconds)} — ${_formatDurationSeconds(_endSeconds)}"),
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
                            // keep minimal gap
                            _endSeconds = (_startSeconds + 0.5).clamp(0.0, totalDuration);
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
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: (_isProcessing || totalDuration <= 0) ? null : _trimAndExtract,
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
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: _playExtracted,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text("Play"),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: _shareExtracted,
                    icon: const Icon(Icons.share),
                    label: const Text("Share"),
                  ),
                ],
              ),
            ],
            const Spacer(),
            // small help text
            const Text(
              "Output will be saved to your app's Documents folder and visible in Files app if you enabled file sharing in Info.plist.",
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
