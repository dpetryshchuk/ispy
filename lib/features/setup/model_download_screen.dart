import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

class ModelDownloadScreen extends StatefulWidget {
  final VoidCallback onModelReady;
  const ModelDownloadScreen({super.key, required this.onModelReady});

  @override
  State<ModelDownloadScreen> createState() => _ModelDownloadScreenState();
}

class _ModelDownloadScreenState extends State<ModelDownloadScreen> {
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _downloading = false;
  bool _done = false;
  String? _error;
  int _progress = 0;

  static const _defaultUrl =
      'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma4-e4b-it-int4.task';
  static const _modelFileName = 'gemma4-e4b-it-int4.task';
  static const _defaultToken = '';

  @override
  void initState() {
    super.initState();
    _urlController.text = _defaultUrl;
    _tokenController.text = _defaultToken;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    final url = _urlController.text.trim();
    final token = _tokenController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _downloading = true;
      _error = null;
      _progress = 0;
    });

    try {
      // Reinitialize with HuggingFace token if provided
      if (token.isNotEmpty) {
        await FlutterGemma.initialize(huggingFaceToken: token);
      }

      final manager = FlutterGemmaPlugin.instance.modelManager;
      // ignore: deprecated_member_use
      final stream = manager.downloadModelWithProgress(
        // Build an InferenceModelSpec from the legacy URL
        // ignore: deprecated_member_use
        InferenceModelSpec.fromLegacyUrl(
          name: _modelFileName,
          modelUrl: url,
        ),
        token: token.isNotEmpty ? token : null,
      );

      await for (final p in stream) {
        if (mounted) setState(() => _progress = p.overallProgress);
      }

      // Set the model path so GemmaService can load it
      // ignore: deprecated_member_use
      await manager.setModelPath(
        (await _getModelPath()),
      );

      if (mounted) {
        setState(() { _done = true; _downloading = false; _progress = 100; });
        await Future.delayed(const Duration(milliseconds: 600));
        widget.onModelReady();
      }
    } catch (e) {
      if (mounted) {
        setState(() { _downloading = false; _error = e.toString(); });
      }
    }
  }

  Future<String> _getModelPath() async {
    final manager = FlutterGemmaPlugin.instance.modelManager;
    // ignore: deprecated_member_use
    final spec = InferenceModelSpec.fromLegacyUrl(
      name: _modelFileName,
      modelUrl: _urlController.text.trim(),
    );
    final paths = await manager.getModelFilePaths(spec);
    return paths?.values.first ?? _modelFileName;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 64),
              const Text(
                'ispy',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  letterSpacing: 8,
                  fontWeight: FontWeight.w100,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'needs a model to think.',
                style: TextStyle(color: Color(0x3DFFFFFF), fontSize: 13),
              ),
              const SizedBox(height: 48),
              const Text(
                'huggingface token',
                style: TextStyle(color: Color(0x3DFFFFFF), fontSize: 11, letterSpacing: 1),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _tokenController,
                enabled: !_downloading,
                obscureText: true,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: const InputDecoration(
                  hintText: 'hf_xxxxxxxxxxxxxxxxxxxx',
                  hintStyle: TextStyle(color: Color(0x28FFFFFF)),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0x1FFFFFFF))),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0x3DFFFFFF))),
                  disabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0x0FFFFFFF))),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'get a free token at huggingface.co/settings/tokens\nthen accept the Gemma model license on huggingface.co/litert-community/Gemma3-1B-IT',
                style: TextStyle(color: Color(0x28FFFFFF), fontSize: 10, height: 1.5),
              ),
              const SizedBox(height: 28),
              const Text(
                'model url',
                style: TextStyle(color: Color(0x3DFFFFFF), fontSize: 11, letterSpacing: 1),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _urlController,
                enabled: !_downloading,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: const InputDecoration(
                  hintText: 'direct .task file URL',
                  hintStyle: TextStyle(color: Color(0x28FFFFFF)),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0x1FFFFFFF))),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0x3DFFFFFF))),
                  disabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0x0FFFFFFF))),
                ),
                maxLines: 2,
                minLines: 1,
              ),
              const SizedBox(height: 40),
              if (_downloading) ...[
                Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: _progress > 0 ? _progress / 100.0 : null,
                        backgroundColor: const Color(0x14FFFFFF),
                        valueColor: const AlwaysStoppedAnimation<Color>(Color(0x60FFFFFF)),
                        minHeight: 1,
                      ),
                    ),
                    if (_progress > 0) ...[
                      const SizedBox(width: 12),
                      Text('$_progress%', style: const TextStyle(color: Color(0x3DFFFFFF), fontSize: 11)),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                const Text('downloading…', style: TextStyle(color: Color(0x3DFFFFFF), fontSize: 11)),
              ] else if (_done) ...[
                const Text('ready.', style: TextStyle(color: Color(0x60FFFFFF), fontSize: 13)),
              ] else ...[
                GestureDetector(
                  onTap: _download,
                  child: const Text(
                    'download',
                    style: TextStyle(color: Color(0x60FFFFFF), fontSize: 13, letterSpacing: 1),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 24),
                Text(
                  _error!,
                  style: const TextStyle(color: Color(0x60FF6666), fontSize: 11, height: 1.5),
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: _download,
                  child: const Text('retry', style: TextStyle(color: Color(0x40FFFFFF), fontSize: 11)),
                ),
              ],
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
