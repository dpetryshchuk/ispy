import 'dart:io';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class GemmaService {
  static const _modelFileName = 'gemma4-e4b-it-int4.task';
  InferenceModel? _model;
  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;

  Future<String> get modelPath async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, _modelFileName);
  }

  Future<bool> modelExists() async => File(await modelPath).exists();

  Future<void> load() async {
    if (_isLoaded) return;
    final path = await modelPath;
    if (!await File(path).exists()) throw Exception('Model not found at $path');
    await FlutterGemmaPlugin.instance.modelManager.setModelPath(path); // ignore: deprecated_member_use
    _model = await FlutterGemmaPlugin.instance.createModel(
      modelType: ModelType.gemmaIt,
      supportImage: true,
      preferredBackend: PreferredBackend.gpu,
    );
    _isLoaded = true;
  }

  InferenceModel get model {
    if (_model == null) throw StateError('model not loaded');
    return _model!;
  }

  /// Single-shot image description — no tools, pure vision.
  Future<String> describeImage({
    required File imageFile,
    required String prompt,
  }) async {
    final session = await model.createSession();
    final bytes = await imageFile.readAsBytes();
    await session.addQueryChunk(Message.withImage(text: prompt, imageBytes: bytes));
    final buf = StringBuffer();
    await for (final token in session.getResponseAsync()) {
      buf.write(token);
    }
    await session.close();
    return buf.toString().trim();
  }

  Future<void> dispose() async {
    await _model?.close();
    _model = null;
    _isLoaded = false;
  }
}
