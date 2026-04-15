import 'dart:io';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class GemmaService {
  static const _modelFileName = 'gemma4-e4b-it-int4.task';
  InferenceModel? _model;
  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;

  /// Path where the model file should be placed.
  /// For POC: place model file in app documents directory or app bundle.
  Future<String> get modelPath async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, _modelFileName);
  }

  Future<bool> modelExists() async {
    final path = await modelPath;
    return File(path).exists();
  }

  /// Load the model. Throws a descriptive error if model file not found.
  Future<void> load() async {
    if (_isLoaded) return;
    final path = await modelPath;
    if (!await File(path).exists()) {
      throw Exception(
        'Gemma 4 E4B model not found.\n\n'
        'Download gemma4-e4b-it-int4.task from:\n'
        'https://www.kaggle.com/models/google/gemma\n\n'
        'Then place it at:\n$path',
      );
    }
    _model = await InferenceModel.create(
      modelPath: path,
      preferredBackend: PreferredBackend.gpu,
    );
    _isLoaded = true;
  }

  /// Single-turn text generation. No tool loop.
  Future<String> generate(String prompt) async {
    if (!_isLoaded || _model == null) throw StateError('model not loaded');
    final session = await _model!.createSession();
    await session.addQueryChunk(TextPart(text: prompt));
    final response = StringBuffer();
    await for (final token in session.generateCandidates()) {
      response.write(token);
    }
    await session.close();
    return response.toString().trim();
  }

  /// Multimodal generation — image + text prompt.
  Future<String> generateWithImage({
    required File imageFile,
    required String prompt,
  }) async {
    if (!_isLoaded || _model == null) throw StateError('model not loaded');
    final session = await _model!.createSession();
    final imageBytes = await imageFile.readAsBytes();
    await session.addQueryChunk(ImagePart(bytes: imageBytes));
    await session.addQueryChunk(TextPart(text: prompt));
    final response = StringBuffer();
    await for (final token in session.generateCandidates()) {
      response.write(token);
    }
    await session.close();
    return response.toString().trim();
  }

  Future<void> dispose() async {
    await _model?.close();
    _model = null;
    _isLoaded = false;
  }
}
