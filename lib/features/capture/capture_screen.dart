import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:ispy_ios/core/agent/agent_harness.dart';
import 'package:ispy_ios/core/agent/prompts.dart';
import 'package:ispy_ios/core/agent/tools.dart';
import 'package:ispy_ios/core/filesystem/log_store.dart';
import 'package:ispy_ios/core/model/gemma_service.dart';
import 'package:ispy_ios/core/vision/exif_extractor.dart';

enum _CaptureState { idle, awaitingContext, processing, done, error }

class CaptureScreen extends StatefulWidget {
  final GemmaService gemmaService;
  const CaptureScreen({super.key, required this.gemmaService});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  CameraController? _cameraController;
  _CaptureState _state = _CaptureState.idle;
  final TextEditingController _contextController = TextEditingController();
  XFile? _pendingPhoto;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    _cameraController = CameraController(
      cameras.first,
      ResolutionPreset.high,
      enableAudio: false,
    );
    await _cameraController!.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _onShutter() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    final photo = await _cameraController!.takePicture();
    setState(() {
      _pendingPhoto = photo;
      _state = _CaptureState.awaitingContext;
    });
  }

  Future<void> _onProcess() async {
    if (_pendingPhoto == null) return;
    setState(() => _state = _CaptureState.processing);
    FocusManager.instance.primaryFocus?.unfocus();

    try {
      final photoFile = File(_pendingPhoto!.path);
      final photoBytes = await photoFile.readAsBytes();

      final extractor = ExifExtractor();
      final exifData = await extractor.extract(photoFile);

      final docsDir = await getApplicationDocumentsDirectory();
      final logStore = LogStore(baseDir: docsDir.path);
      final tools = AgentTools(baseDir: docsDir.path);
      final harness = AgentHarness(gemma: widget.gemmaService, tools: tools);

      // Pre-create log folder + save photo.
      // ispy writes entry.md itself via write_file tool.
      final logEntryPath = await logStore.createFolder(
        timestamp: exifData.capturedAt.toUtc(),
        photoBytes: photoBytes,
      );
      final logEntryRelative =
          '${p.relative(logEntryPath, from: docsDir.path).replaceAll('\\', '/')}/entry.md';

      // Stage 1: pure visual observation (no character)
      final stage1 = await widget.gemmaService.generateWithImage(
        imageFile: photoFile,
        prompt: Prompts.stage1VisionPrompt,
      );

      // Stage 2: ispy agent loop — navigates wiki, writes entry, updates wiki
      await harness.run(
        systemPrompt: Prompts.ispySystemPrompt,
        userPrompt: Prompts.stage2CapturePrompt(
          stage1Observations: stage1,
          exifData: exifData,
          logEntryPath: logEntryRelative,
          userContext: _contextController.text.trim().isEmpty
              ? null
              : _contextController.text.trim(),
        ),
      );

      if (mounted) {
        setState(() {
          _state = _CaptureState.done;
          _pendingPhoto = null;
          _contextController.clear();
        });
      }
    } catch (e) {
      if (mounted) setState(() => _state = _CaptureState.error);
    }
  }

  void _reset() {
    setState(() {
      _state = _CaptureState.idle;
      _pendingPhoto = null;
      _contextController.clear();
    });
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _contextController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: (_state == _CaptureState.done || _state == _CaptureState.error)
            ? _reset
            : null,
        child: Stack(
          children: [
            // Camera preview
            if (_cameraController?.value.isInitialized == true &&
                _state == _CaptureState.idle)
              Positioned.fill(child: CameraPreview(_cameraController!)),

            // Shutter button
            if (_state == _CaptureState.idle)
              Positioned(
                bottom: 64,
                left: 0,
                right: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: _onShutter,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                      child: const Center(
                        child: CircleAvatar(
                          radius: 28,
                          backgroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // Context input (after shutter, before processing)
            if (_state == _CaptureState.awaitingContext)
              Positioned.fill(
                child: Container(
                  color: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'ispy is ready.',
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 13,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 32),
                      TextField(
                        controller: _contextController,
                        autofocus: true,
                        style: const TextStyle(color: Colors.white, fontSize: 15),
                        decoration: const InputDecoration(
                          hintText: 'add context (optional)',
                          hintStyle: TextStyle(color: Colors.white24),
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: Colors.white12),
                          ),
                          focusedBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: Colors.white38),
                          ),
                        ),
                        onSubmitted: (_) => _onProcess(),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton(
                            onPressed: _reset,
                            child: const Text(
                              'cancel',
                              style: TextStyle(color: Colors.white24, fontSize: 12),
                            ),
                          ),
                          const SizedBox(width: 24),
                          TextButton(
                            onPressed: _onProcess,
                            child: const Text(
                              'done',
                              style: TextStyle(color: Colors.white54, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

            // Status overlay (processing / done / error)
            if (_state == _CaptureState.processing ||
                _state == _CaptureState.done ||
                _state == _CaptureState.error)
              Positioned.fill(
                child: Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: Text(
                    _statusText,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 14,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String get _statusText {
    switch (_state) {
      case _CaptureState.processing:
        return 'ispy is looking.';
      case _CaptureState.done:
        return 'ispy looked.';
      case _CaptureState.error:
        return 'ispy could not see.';
      default:
        return '';
    }
  }
}
