import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/ffmpeg_kit.dart';

class AudioExtractorPage extends StatefulWidget {
  @override
  State<AudioExtractorPage> createState() => _AudioExtractorPageState();
}

class _AudioExtractorPageState extends State<AudioExtractorPage> {
  bool isProcessing = false;
  String status = "";

  Future<void> pickVideo() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.video,
    );

    if (result != null) {
      String videoPath = result.files.single.path!;
      await extractAudio(videoPath);
    }
  }

  Future<void> extractAudio(String videoPath) async {
    setState(() {
      isProcessing = true;
      status = "Extracting audio...";
    });

    // Output path — iOS visible folder
    Directory docs = await getApplicationDocumentsDirectory();
    String outputPath =
        "${docs.path}/audio_${DateTime.now().millisecondsSinceEpoch}.mp3";

    String command = "-i \"$videoPath\" -vn -acodec libmp3lame \"$outputPath\"";

    await FFmpegKit.executeAsync(command, (session) async {
      final returnCode = await session.getReturnCode();

      if (returnCode?.isValueSuccess() ?? false) {
        setState(() {
          status = "Saved in Files:\n$outputPath\n\n"
              "Open: Files → On My iPhone → YourAppName";
        });
      } else {
        setState(() {
          status = "Extraction failed!";
        });
      }

      isProcessing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Audio Extractor")),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: isProcessing ? null : pickVideo,
                child: Text("Pick Video"),
              ),
              SizedBox(height: 30),
              if (isProcessing) CircularProgressIndicator(),
              SizedBox(height: 20),
              Text(status, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
