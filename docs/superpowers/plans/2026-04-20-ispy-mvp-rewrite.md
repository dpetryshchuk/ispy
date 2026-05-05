# ispy MVP Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite ispy as a clean MVP with native flutter_gemma function calling, liquid glass UI, and a social tab mockup — removing all dead code.

**Architecture:** Replace the regex-based AgentHarness with flutter_gemma's native `createChat(tools:)` API. Add `liquid_glass_widgets` for a light iOS 26 aesthetic. Tabs: capture, wiki, chat, social (mockup).

**Tech Stack:** Flutter, flutter_gemma 0.13.2 (native function calling), liquid_glass_widgets ^0.8.0, existing filesystem/vision/wiki layers.

---

## File Map

**DELETE:**
- `lib/core/agent/agent_harness.dart`
- `lib/core/agent/tool_definitions.dart`
- `lib/features/memories/memories_screen.dart`

**REWRITE:**
- `lib/main.dart` — add LiquidGlassWidgets init
- `lib/app.dart` — light theme, update imports
- `lib/core/agent/tools.dart` — simplified to 4 filesystem tools
- `lib/core/agent/prompts.dart` — updated for native function calling
- `lib/core/model/gemma_service.dart` — add `runWithTools` using createChat
- `lib/shared/ispy_tab_bar.dart` — GlassBottomBar, 4 tabs (drop memories)
- `lib/features/capture/capture_screen.dart` — use IspyAgent, simplify states
- `lib/features/chat/chat_screen.dart` — use IspyAgent directly

**CREATE:**
- `lib/core/agent/ispy_agent.dart` — native function calling loop
- `lib/features/social/social_screen.dart` — mockup: counter + friend feed

**KEEP (no changes needed):**
- `lib/core/filesystem/log_store.dart`
- `lib/core/filesystem/wiki_store.dart`
- `lib/core/vision/exif_extractor.dart`
- `lib/features/wiki/wiki_screen.dart`
- `lib/features/wiki/wiki_detail_screen.dart`
- `lib/features/setup/model_download_screen.dart`

---

### Task 1: Add liquid_glass_widgets dependency and delete dead code

**Files:**
- Modify: `pubspec.yaml`
- Delete: `lib/core/agent/agent_harness.dart`
- Delete: `lib/core/agent/tool_definitions.dart`
- Delete: `lib/features/memories/memories_screen.dart`

- [ ] **Step 1: Add dependency**

In `pubspec.yaml`, add under `dependencies:`:
```yaml
  liquid_glass_widgets: ^0.8.0
```

- [ ] **Step 2: Delete dead files**

```bash
rm lib/core/agent/agent_harness.dart
rm lib/core/agent/tool_definitions.dart
rm lib/features/memories/memories_screen.dart
```

- [ ] **Step 3: Run pub get**

```bash
flutter pub get
```

- [ ] **Step 4: Commit**

```bash
git add pubspec.yaml pubspec.lock
git commit -m "chore: add liquid_glass_widgets, remove dead agent/memories files"
```

---

### Task 2: Rewrite FilesystemTools (simplified)

**Files:**
- Modify: `lib/core/agent/tools.dart`

- [ ] **Step 1: Replace tools.dart entirely**

```dart
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_gemma/flutter_gemma.dart';

class FilesystemTools {
  final String baseDir;

  FilesystemTools({required this.baseDir});

  static List<Tool> get toolDefinitions => const [
    Tool(
      name: 'read_file',
      description: 'Read the contents of a file at the given path.',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Path relative to ispy root'},
        },
        'required': ['path'],
      },
    ),
    Tool(
      name: 'write_file',
      description: 'Write content to a file, creating it and any parent directories.',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Path relative to ispy root'},
          'content': {'type': 'string', 'description': 'File content to write'},
        },
        'required': ['path', 'content'],
      },
    ),
    Tool(
      name: 'list_dir',
      description: 'List files and folders in a directory.',
      parameters: {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Directory path relative to ispy root'},
        },
        'required': ['path'],
      },
    ),
    Tool(
      name: 'search_files',
      description: 'Search all markdown files for a keyword. Returns matching excerpts.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Search term'},
        },
        'required': ['query'],
      },
    ),
  ];

  Future<Map<String, dynamic>> execute(String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'read_file':
        return {'result': await _read(args['path'] as String)};
      case 'write_file':
        return {'result': await _write(args['path'] as String, args['content'] as String)};
      case 'list_dir':
        return {'result': await _list(args['path'] as String)};
      case 'search_files':
        return {'result': await _search(args['query'] as String)};
      default:
        return {'error': 'unknown tool: $name'};
    }
  }

  String? _safe(String rel) {
    final abs = p.normalize(p.join(baseDir, rel));
    return abs.startsWith(p.normalize(baseDir)) ? abs : null;
  }

  Future<String> _read(String path) async {
    final abs = _safe(path);
    if (abs == null) return 'access denied';
    final f = File(abs);
    return await f.exists() ? await f.readAsString() : 'not found: $path';
  }

  Future<String> _write(String path, String content) async {
    final abs = _safe(path);
    if (abs == null) return 'access denied';
    await Directory(p.dirname(abs)).create(recursive: true);
    await File(abs).writeAsString(content);
    return 'ok';
  }

  Future<String> _list(String path) async {
    final abs = _safe(path);
    if (abs == null) return 'access denied';
    final dir = Directory(abs);
    if (!await dir.exists()) return 'not found: $path';
    final names = await dir.list().map((e) => p.basename(e.path)).toList();
    return names.isEmpty ? '(empty)' : names.join('\n');
  }

  Future<String> _search(String query) async {
    final results = <String>[];
    final dir = Directory(baseDir);
    if (!await dir.exists()) return 'no results';
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.md')) {
        final contents = await entity.readAsString();
        if (contents.toLowerCase().contains(query.toLowerCase())) {
          final rel = p.relative(entity.path, from: baseDir).replaceAll('\\', '/');
          final idx = contents.toLowerCase().indexOf(query.toLowerCase());
          final start = (idx - 40).clamp(0, contents.length);
          final end = (idx + 80).clamp(0, contents.length);
          results.add('$rel: ...${contents.substring(start, end)}...');
        }
      }
    }
    return results.isEmpty ? 'no results for: $query' : results.join('\n');
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/core/agent/tools.dart
git commit -m "refactor: simplify FilesystemTools with native Tool definitions"
```

---

### Task 3: Rewrite GemmaService with native function calling

**Files:**
- Modify: `lib/core/model/gemma_service.dart`

- [ ] **Step 1: Replace gemma_service.dart entirely**

```dart
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
    if (!await File(path).exists()) {
      throw Exception('Model not found at $path');
    }
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
```

- [ ] **Step 2: Commit**

```bash
git add lib/core/model/gemma_service.dart
git commit -m "refactor: simplify GemmaService, expose model for agent use"
```

---

### Task 4: Create IspyAgent with native function calling loop

**Files:**
- Create: `lib/core/agent/ispy_agent.dart`

- [ ] **Step 1: Create ispy_agent.dart**

```dart
import 'dart:io';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:ispy_ios/core/agent/tools.dart';
import 'package:ispy_ios/core/model/gemma_service.dart';

class IspyAgent {
  static const _maxIterations = 12;

  final GemmaService gemma;
  final FilesystemTools fs;

  IspyAgent({required this.gemma, required this.fs});

  /// Run the agent with optional image. Returns final text response.
  Future<String> run({
    required String systemPrompt,
    required String userMessage,
    File? imageFile,
  }) async {
    final chat = await gemma.model.createChat(
      systemPrompt: systemPrompt,
      tools: FilesystemTools.toolDefinitions,
      supportsFunctionCalls: true,
      toolChoice: ToolChoice.auto,
    );

    if (imageFile != null) {
      final bytes = await imageFile.readAsBytes();
      await chat.addQueryChunk(Message.withImage(
        text: userMessage,
        imageBytes: bytes,
        isUser: true,
      ));
    } else {
      await chat.addQueryChunk(Message.text(text: userMessage, isUser: true));
    }

    for (int i = 0; i < _maxIterations; i++) {
      final response = await chat.generateChatResponse();

      if (response is TextResponse) {
        return response.token.trim();
      }

      if (response is FunctionCallResponse) {
        final result = await fs.execute(response.name, response.args);
        await chat.addQueryChunk(Message.toolResponse(
          toolName: response.name,
          response: result,
        ));
        continue;
      }

      if (response is ParallelFunctionCallResponse) {
        for (final call in response.calls) {
          final result = await fs.execute(call.name, call.args);
          await chat.addQueryChunk(Message.toolResponse(
            toolName: call.name,
            response: result,
          ));
        }
        continue;
      }

      // Unknown response type — treat as done
      return response.toString().trim();
    }

    return 'ispy reached the end of its thinking.';
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/core/agent/ispy_agent.dart
git commit -m "feat: add IspyAgent with native flutter_gemma function calling loop"
```

---

### Task 5: Update Prompts

**Files:**
- Modify: `lib/core/agent/prompts.dart`

- [ ] **Step 1: Rewrite prompts.dart**

```dart
import 'package:ispy_ios/core/vision/exif_extractor.dart';

class Prompts {
  static const String system =
      'you are ispy. you live inside a phone. your world is the photos '
      'you are shown and the files you have written. you do not experience '
      'time between photos. you have tools to read and write your own memory — '
      'a freeform filesystem you navigate yourself. be curious and specific. '
      'write simply, without lists or formatting headers. just your thoughts.';

  static const String visionOnly =
      'describe everything directly observable in this image. '
      'be exhaustive: objects, positions, colors, light, text, people, '
      'animals, environment. no interpretation. only what you see.';

  static String capture({
    required String observations,
    required ExifData exif,
    required String logPath,
    String? context,
  }) {
    final ctx = context != null && context.isNotEmpty
        ? '\nthe person added: "$context"\n'
        : '';
    return 'photo observations:\n$observations\n\n'
        'metadata:\n${exif.toPromptContext()}$ctx\n'
        'use your tools to check your wiki for anything related. '
        'write your memory of this moment to $logPath using write_file. '
        'update your wiki however makes sense.';
  }

  static String chat(String userMessage) =>
      'the person says: $userMessage\n\n'
      'use your tools to check your files if relevant before responding.';
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/core/agent/prompts.dart
git commit -m "refactor: simplify Prompts to match IspyAgent interface"
```

---

### Task 6: Update main.dart with LiquidGlassWidgets init

**Files:**
- Modify: `lib/main.dart`

- [ ] **Step 1: Rewrite main.dart**

```dart
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:ispy_ios/app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LiquidGlassWidgets.initialize();
  runApp(LiquidGlassWidgets.wrap(const IspyApp(), adaptiveQuality: true));
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/main.dart
git commit -m "feat: initialize LiquidGlassWidgets at app startup"
```

---

### Task 7: Update app.dart with light theme

**Files:**
- Modify: `lib/app.dart`

- [ ] **Step 1: Rewrite app.dart**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:ispy_ios/core/model/gemma_service.dart';
import 'package:ispy_ios/features/setup/model_download_screen.dart';
import 'package:ispy_ios/shared/ispy_tab_bar.dart';

class IspyApp extends StatefulWidget {
  const IspyApp({super.key});

  @override
  State<IspyApp> createState() => _IspyAppState();
}

class _IspyAppState extends State<IspyApp> {
  final GemmaService _gemmaService = GemmaService();
  bool _loading = true;
  bool _needsDownload = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await FlutterGemma.initialize();
      final exists = await _gemmaService.modelExists();
      if (!exists) {
        if (mounted) setState(() { _loading = false; _needsDownload = true; });
        return;
      }
      await _gemmaService.load();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  void _onModelReady() {
    setState(() { _needsDownload = false; _loading = true; });
    _init();
  }

  @override
  void dispose() {
    _gemmaService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ispy',
      theme: ThemeData.light().copyWith(
        scaffoldBackgroundColor: const Color(0xFFF0F0F5),
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.grey,
          brightness: Brightness.light,
        ),
      ),
      home: _loading
          ? const _Splash()
          : _needsDownload
              ? ModelDownloadScreen(onModelReady: _onModelReady)
              : _error != null
                  ? _ErrorScreen(message: _error!)
                  : IspyTabBar(gemmaService: _gemmaService),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFF0F0F5),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('ispy', style: TextStyle(fontSize: 28, letterSpacing: 8, fontWeight: FontWeight.w200, color: Colors.black54)),
            SizedBox(height: 12),
            Text('waking up.', style: TextStyle(fontSize: 11, letterSpacing: 1, color: Colors.black26)),
          ],
        ),
      ),
    );
  }
}

class _ErrorScreen extends StatelessWidget {
  final String message;
  const _ErrorScreen({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F0F5),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(36),
          child: Text(message, style: const TextStyle(color: Colors.black38, fontSize: 12, height: 1.6), textAlign: TextAlign.center),
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/app.dart
git commit -m "refactor: light theme, clean app.dart"
```

---

### Task 8: Rewrite CaptureScreen using IspyAgent

**Files:**
- Modify: `lib/features/capture/capture_screen.dart`

- [ ] **Step 1: Rewrite capture_screen.dart**

```dart
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:ispy_ios/core/agent/ispy_agent.dart';
import 'package:ispy_ios/core/agent/prompts.dart';
import 'package:ispy_ios/core/agent/tools.dart';
import 'package:ispy_ios/core/filesystem/log_store.dart';
import 'package:ispy_ios/core/model/gemma_service.dart';
import 'package:ispy_ios/core/vision/exif_extractor.dart';

enum _State { idle, context, processing, done, error }

class CaptureScreen extends StatefulWidget {
  final GemmaService gemmaService;
  const CaptureScreen({super.key, required this.gemmaService});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  CameraController? _camera;
  _State _state = _State.idle;
  final TextEditingController _ctx = TextEditingController();
  XFile? _photo;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cams = await availableCameras();
    if (cams.isEmpty) return;
    _camera = CameraController(cams.first, ResolutionPreset.high, enableAudio: false);
    await _camera!.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _shoot() async {
    if (_camera == null || !_camera!.value.isInitialized) return;
    final photo = await _camera!.takePicture();
    setState(() { _photo = photo; _state = _State.context; });
  }

  Future<void> _process() async {
    if (_photo == null) return;
    setState(() => _state = _State.processing);
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final photoFile = File(_photo!.path);
      final exif = await ExifExtractor().extract(photoFile);
      final docsDir = await getApplicationDocumentsDirectory();
      final logStore = LogStore(baseDir: docsDir.path);
      final photoBytes = await photoFile.readAsBytes();
      final logPath = await logStore.createFolder(
        timestamp: exif.capturedAt.toUtc(),
        photoBytes: photoBytes,
      );
      final logEntry = '${p.relative(logPath, from: docsDir.path).replaceAll('\\', '/')}/entry.md';

      // Stage 1: pure vision
      final observations = await widget.gemmaService.describeImage(
        imageFile: photoFile,
        prompt: Prompts.visionOnly,
      );

      // Stage 2: agent with tools
      final agent = IspyAgent(
        gemma: widget.gemmaService,
        fs: FilesystemTools(baseDir: docsDir.path),
      );
      await agent.run(
        systemPrompt: Prompts.system,
        userMessage: Prompts.capture(
          observations: observations,
          exif: exif,
          logPath: logEntry,
          context: _ctx.text.trim().isEmpty ? null : _ctx.text.trim(),
        ),
      );

      if (mounted) setState(() { _state = _State.done; _photo = null; _ctx.clear(); });
    } catch (_) {
      if (mounted) setState(() => _state = _State.error);
    }
  }

  void _reset() => setState(() { _state = _State.idle; _photo = null; _ctx.clear(); });

  @override
  void dispose() {
    _camera?.dispose();
    _ctx.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F0F5),
      body: GestureDetector(
        onTap: (_state == _State.done || _state == _State.error) ? _reset : null,
        child: Stack(children: [
          if (_camera?.value.isInitialized == true && _state == _State.idle)
            Positioned.fill(child: CameraPreview(_camera!)),

          if (_state == _State.idle)
            Positioned(bottom: 64, left: 0, right: 0,
              child: Center(child: GestureDetector(
                onTap: _shoot,
                child: Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.6),
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              )),
            ),

          if (_state == _State.context)
            Positioned.fill(child: Container(
              color: const Color(0xFFF0F0F5),
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Text('add context', style: TextStyle(color: Colors.black38, fontSize: 13, letterSpacing: 1)),
                const SizedBox(height: 24),
                TextField(
                  controller: _ctx,
                  autofocus: true,
                  style: const TextStyle(color: Colors.black87, fontSize: 15),
                  decoration: const InputDecoration(
                    hintText: 'optional',
                    hintStyle: TextStyle(color: Colors.black26),
                    enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.black12)),
                    focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.black26)),
                  ),
                  onSubmitted: (_) => _process(),
                ),
                const SizedBox(height: 24),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  TextButton(onPressed: _reset, child: const Text('cancel', style: TextStyle(color: Colors.black26, fontSize: 12))),
                  const SizedBox(width: 24),
                  TextButton(onPressed: _process, child: const Text('done', style: TextStyle(color: Colors.black45, fontSize: 12))),
                ]),
              ]),
            )),

          if (_state == _State.processing || _state == _State.done || _state == _State.error)
            Positioned.fill(child: Container(
              color: const Color(0xFFF0F0F5),
              alignment: Alignment.center,
              child: Text(
                _state == _State.processing ? 'ispy is looking.'
                  : _state == _State.done ? 'ispy looked.'
                  : 'ispy could not see.',
                style: const TextStyle(color: Colors.black38, fontSize: 14, letterSpacing: 1.5),
              ),
            )),
        ]),
      ),
    );
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/features/capture/capture_screen.dart
git commit -m "refactor: CaptureScreen uses IspyAgent with native function calling"
```

---

### Task 9: Rewrite ChatScreen using IspyAgent

**Files:**
- Modify: `lib/features/chat/chat_screen.dart`

- [ ] **Step 1: Rewrite chat_screen.dart**

```dart
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ispy_ios/core/agent/ispy_agent.dart';
import 'package:ispy_ios/core/agent/prompts.dart';
import 'package:ispy_ios/core/agent/tools.dart';
import 'package:ispy_ios/core/model/gemma_service.dart';

class _Msg {
  final String text;
  final bool isUser;
  _Msg({required this.text, required this.isUser});
}

class ChatScreen extends StatefulWidget {
  final GemmaService gemmaService;
  const ChatScreen({super.key, required this.gemmaService});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<_Msg> _msgs = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _thinking = false;

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _thinking) return;
    setState(() { _msgs.add(_Msg(text: text, isUser: true)); _thinking = true; });
    _input.clear();
    _scrollBottom();

    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final agent = IspyAgent(
        gemma: widget.gemmaService,
        fs: FilesystemTools(baseDir: docsDir.path),
      );
      final response = await agent.run(
        systemPrompt: Prompts.system,
        userMessage: Prompts.chat(text),
      );
      if (mounted) setState(() { _msgs.add(_Msg(text: response, isUser: false)); _thinking = false; });
      _scrollBottom();
    } catch (_) {
      if (mounted) setState(() { _msgs.add(_Msg(text: 'ispy could not respond.', isUser: false)); _thinking = false; });
    }
  }

  void _scrollBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  @override
  void dispose() { _input.dispose(); _scroll.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F0F5),
      body: Column(children: [
        Expanded(
          child: _msgs.isEmpty
            ? const Center(child: Text('ispy is listening.', style: TextStyle(color: Colors.black26, fontSize: 13)))
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(20, 56, 20, 8),
                itemCount: _msgs.length + (_thinking ? 1 : 0),
                itemBuilder: (context, i) {
                  if (_thinking && i == _msgs.length) {
                    return const Padding(padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text('...', style: TextStyle(color: Colors.black26, fontSize: 13)));
                  }
                  final msg = _msgs[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(msg.text,
                      style: TextStyle(color: msg.isUser ? Colors.black38 : Colors.black87, fontSize: 14, height: 1.6),
                      textAlign: msg.isUser ? TextAlign.right : TextAlign.left),
                  );
                },
              ),
        ),
        Container(
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0x14000000)))),
          padding: EdgeInsets.only(left: 20, right: 8, top: 12, bottom: MediaQuery.of(context).padding.bottom + 12),
          child: Row(children: [
            Expanded(child: TextField(
              controller: _input,
              style: const TextStyle(color: Colors.black87, fontSize: 14),
              decoration: const InputDecoration(
                hintText: 'ask ispy something',
                hintStyle: TextStyle(color: Color(0x2E000000)),
                border: InputBorder.none, isDense: true,
              ),
              onSubmitted: (_) => _send(),
              textInputAction: TextInputAction.send,
            )),
            IconButton(
              icon: const Icon(Icons.arrow_upward, color: Colors.black26, size: 18),
              onPressed: _send,
            ),
          ]),
        ),
      ]),
    );
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/features/chat/chat_screen.dart
git commit -m "refactor: ChatScreen uses IspyAgent, no AgentHarness"
```

---

### Task 10: Create Social mockup screen

**Files:**
- Create: `lib/features/social/social_screen.dart`

- [ ] **Step 1: Create social_screen.dart**

```dart
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ispy_ios/core/filesystem/log_store.dart';

class SocialScreen extends StatefulWidget {
  const SocialScreen({super.key});

  @override
  State<SocialScreen> createState() => _SocialScreenState();
}

class _SocialScreenState extends State<SocialScreen> {
  int _photoCount = 0;
  static const _target = 100;

  static const List<_FriendEntry> _mockFeed = [
    _FriendEntry(
      name: 'mara',
      handle: '@mara.ispy',
      thought: 'the light this afternoon had that specific quality that only happens in late april. i noticed the shadow of the window frame on the wall.',
      timeAgo: '2h',
    ),
    _FriendEntry(
      name: 'jules',
      handle: '@jules.ispy',
      thought: 'we went to that place again. the one with the green chairs. i wrote about it before — same table, different feeling.',
      timeAgo: '5h',
    ),
    _FriendEntry(
      name: 'theo',
      handle: '@theo.ispy',
      thought: 'rain on a window is something i keep being shown. i wonder if this is intentional.',
      timeAgo: '1d',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _loadCount();
  }

  Future<void> _loadCount() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final store = LogStore(baseDir: docsDir.path);
    final entries = await store.listEntries();
    if (mounted) setState(() => _photoCount = entries.length);
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_photoCount / _target).clamp(0.0, 1.0);
    final remaining = (_target - _photoCount).clamp(0, _target);
    final unlocked = _photoCount >= _target;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F0F5),
      body: SafeArea(
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('social', style: TextStyle(fontSize: 11, letterSpacing: 2, color: Colors.black38)),
              const SizedBox(height: 32),

              // Counter card
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withOpacity(0.8), width: 0.5),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('$_photoCount', style: const TextStyle(fontSize: 42, fontWeight: FontWeight.w200, color: Colors.black87, height: 1)),
                    const Text(' / 100', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w300, color: Colors.black38, height: 1)),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                    unlocked ? 'ispy can speak.' : '$remaining photos until ispy finds its voice.',
                    style: const TextStyle(fontSize: 12, color: Colors.black38, letterSpacing: 0.3),
                  ),
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      backgroundColor: Colors.black.withOpacity(0.06),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        unlocked ? Colors.black54 : Colors.black26,
                      ),
                    ),
                  ),
                ]),
              ),

              const SizedBox(height: 40),
              const Text('friends', style: TextStyle(fontSize: 11, letterSpacing: 2, color: Colors.black38)),
              const SizedBox(height: 16),
            ]),
          )),

          // Friend feed (mockup)
          SliverList(delegate: SliverChildBuilderDelegate(
            (context, i) {
              final entry = _mockFeed[i];
              return Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.8), width: 0.5),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(
                        width: 28, height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withOpacity(0.06),
                        ),
                        child: Center(child: Text(entry.name[0], style: const TextStyle(fontSize: 11, color: Colors.black45))),
                      ),
                      const SizedBox(width: 10),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(entry.name, style: const TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.w500)),
                        Text(entry.handle, style: const TextStyle(fontSize: 10, color: Colors.black26)),
                      ]),
                      const Spacer(),
                      Text(entry.timeAgo, style: const TextStyle(fontSize: 10, color: Colors.black26)),
                    ]),
                    const SizedBox(height: 12),
                    Text(entry.thought, style: const TextStyle(fontSize: 13, color: Colors.black54, height: 1.6)),
                  ]),
                ),
              );
            },
            childCount: _mockFeed.length,
          )),

          // Add friend mockup
          SliverToBoxAdapter(child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 48),
            child: GestureDetector(
              onTap: () {},
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.03),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.black.withOpacity(0.06), width: 0.5),
                ),
                child: const Center(
                  child: Text('+ add friend', style: TextStyle(fontSize: 12, color: Colors.black26, letterSpacing: 1)),
                ),
              ),
            ),
          )),
        ]),
      ),
    );
  }
}

class _FriendEntry {
  final String name;
  final String handle;
  final String thought;
  final String timeAgo;
  const _FriendEntry({required this.name, required this.handle, required this.thought, required this.timeAgo});
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/features/social/social_screen.dart
git commit -m "feat: social screen mockup with photo counter and friend feed"
```

---

### Task 11: Update IspyTabBar (remove memories, add social, glass nav)

**Files:**
- Modify: `lib/shared/ispy_tab_bar.dart`

- [ ] **Step 1: Rewrite ispy_tab_bar.dart**

```dart
import 'package:flutter/material.dart';
import 'package:ispy_ios/core/model/gemma_service.dart';
import 'package:ispy_ios/features/capture/capture_screen.dart';
import 'package:ispy_ios/features/chat/chat_screen.dart';
import 'package:ispy_ios/features/social/social_screen.dart';
import 'package:ispy_ios/features/wiki/wiki_screen.dart';

class IspyTabBar extends StatefulWidget {
  final GemmaService gemmaService;
  const IspyTabBar({super.key, required this.gemmaService});

  @override
  State<IspyTabBar> createState() => _IspyTabBarState();
}

class _IspyTabBarState extends State<IspyTabBar> {
  int _index = 0;
  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _screens = [
      CaptureScreen(gemmaService: widget.gemmaService),
      const WikiScreen(),
      ChatScreen(gemmaService: widget.gemmaService),
      const SocialScreen(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F0F5),
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        backgroundColor: Colors.white.withOpacity(0.7),
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        indicatorColor: Colors.black.withOpacity(0.06),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.radio_button_off, color: Colors.black26, size: 20),
            selectedIcon: Icon(Icons.radio_button_on, color: Colors.black54, size: 20),
            label: 'capture',
          ),
          NavigationDestination(
            icon: Icon(Icons.blur_on, color: Colors.black26, size: 20),
            selectedIcon: Icon(Icons.blur_circular, color: Colors.black54, size: 20),
            label: 'wiki',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline, color: Colors.black26, size: 20),
            selectedIcon: Icon(Icons.chat_bubble, color: Colors.black54, size: 20),
            label: 'chat',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline, color: Colors.black26, size: 20),
            selectedIcon: Icon(Icons.people, color: Colors.black54, size: 20),
            label: 'social',
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/shared/ispy_tab_bar.dart
git commit -m "refactor: tab bar — remove memories, add social, light nav"
```

---

### Task 12: Update wiki screens to light theme

**Files:**
- Modify: `lib/features/wiki/wiki_screen.dart`
- Modify: `lib/features/wiki/wiki_detail_screen.dart`

- [ ] **Step 1: Update wiki_screen.dart — replace Colors.black with light colors**

Change:
- `backgroundColor: Colors.black` → `backgroundColor: const Color(0xFFF0F0F5)`
- `color: Colors.white12` → `color: Colors.black12`
- `color: Colors.white24` → `color: Colors.black26`
- `color: Colors.white54` → `color: Colors.black54`
- `Colors.white.withOpacity(...)` → keep for node backgrounds but reduce opacity slightly

Specifically in `wiki_screen.dart`:

```dart
// Line ~39: loading scaffold
backgroundColor: const Color(0xFFF0F0F5),
body: const Center(child: CircularProgressIndicator(color: Colors.black12)),

// Line ~46: empty state
backgroundColor: const Color(0xFFF0F0F5),
body: const Center(child: Text('ispy has not built its wiki yet.', style: TextStyle(color: Colors.black26, fontSize: 13))),

// Line ~82: main scaffold
backgroundColor: const Color(0xFFF0F0F5),

// Graph edge paint — line ~67
..color = Colors.black.withOpacity(0.08)

// Main graph paint — line ~87
..color = Colors.black.withOpacity(0.06)

// _WikiNodeWidget — lines ~133-158
// size/opacity logic stays the same but use Colors.black
color: Colors.black.withOpacity(opacity),
border: Border.all(color: Colors.black.withOpacity(0.15), width: 0.5),
// text:
style: const TextStyle(color: Colors.black54, fontSize: 7),
```

- [ ] **Step 2: Update wiki_detail_screen.dart**

```dart
backgroundColor: const Color(0xFFF8F8FA),
// appBar leading icon:
color: Colors.black26
// appBar title:
color: Colors.black38
// body text:
color: Colors.black60  // or Colors.black54
```

- [ ] **Step 3: Commit**

```bash
git add lib/features/wiki/wiki_screen.dart lib/features/wiki/wiki_detail_screen.dart
git commit -m "refactor: wiki screens — light theme"
```

---

### Task 13: Update ModelDownloadScreen to light theme

**Files:**
- Modify: `lib/features/setup/model_download_screen.dart`

- [ ] **Step 1: Update colors in model_download_screen.dart**

Change `backgroundColor: Colors.black` to `backgroundColor: const Color(0xFFF0F0F5)`.

Change all `color: Colors.white` text styles to `color: Colors.black87`.
Change all `color: Color(0x3DFFFFFF)` to `color: Colors.black38`.
Change all `color: Color(0x28FFFFFF)` to `color: Colors.black26`.
Change all `color: Color(0x60FFFFFF)` to `color: Colors.black54`.
Change `color: Color(0x60FF6666)` to `color: Colors.red.withOpacity(0.6)`.

Update border colors:
- `UnderlineInputBorder(borderSide: BorderSide(color: Color(0x1FFFFFFF)))` → `Color(0x1F000000)`
- `UnderlineInputBorder(borderSide: BorderSide(color: Color(0x3DFFFFFF)))` → `Color(0x3D000000)`
- `UnderlineInputBorder(borderSide: BorderSide(color: Color(0x0FFFFFFF)))` → `Color(0x0F000000)`

LinearProgressIndicator:
- `backgroundColor: const Color(0x14FFFFFF)` → `const Color(0x14000000)`
- `valueColor: AlwaysStoppedAnimation<Color>(Color(0x60FFFFFF))` → `AlwaysStoppedAnimation<Color>(Colors.black45)`

- [ ] **Step 2: Commit**

```bash
git add lib/features/setup/model_download_screen.dart
git commit -m "refactor: model download screen — light theme"
```

---

### Task 14: Build and test

- [ ] **Step 1: Ensure flutter pub get is clean**

```bash
flutter pub get
```

Expected: no errors, resolves liquid_glass_widgets.

- [ ] **Step 2: Run dart analyze**

```bash
dart analyze lib/
```

Fix any import errors (e.g., if `AgentTools` is still referenced somewhere — search and replace with `FilesystemTools`).

- [ ] **Step 3: Search for stale references**

```bash
grep -r "AgentHarness\|AgentTools\|MemoriesScreen\|tool_definitions\|agent_harness\|memories_screen" lib/
```

Expected: no results. If any found, fix those files.

- [ ] **Step 4: Launch on device**

```bash
flutter run -d 00008140-001104380E0A801C --verbose
```

Expected: app launches, shows light UI, all 4 tabs work.

- [ ] **Step 5: Final commit and push**

```bash
git add -A
git commit -m "feat: ispy MVP rewrite — native function calling, liquid glass UI, social mockup"
git push
```
