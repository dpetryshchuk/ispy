# ispy — architecture

ispy is a local-first iOS app. A small on-device AI witnesses the user's life through photos, builds its own wiki, and talks to the user. Nothing leaves the phone.

---

## overview

```
┌─────────────────────────────────────────────────┐
│                     UI layer                    │
│  CaptureScreen  ChatScreen  WikiScreen  Social  │
└────────────────┬────────────────────────────────┘
                 │
┌────────────────▼────────────────────────────────┐
│                  agent layer                    │
│  IspyAgent  ──  FilesystemTools  ──  Prompts   │
└────────────────┬────────────────────────────────┘
                 │
┌────────────────▼────────────────────────────────┐
│                  model layer                    │
│            GemmaService (flutter_gemma)         │
│         Gemma 4 E4B, runs on-device via Metal   │
└────────────────┬────────────────────────────────┘
                 │
┌────────────────▼────────────────────────────────┐
│              filesystem layer                   │
│          app Documents directory (sandboxed)    │
│        LogStore  ──  WikiStore (freeform)       │
└─────────────────────────────────────────────────┘
```

---

## layers

### model layer — `lib/core/model/`

`GemmaService` owns the Gemma model lifecycle.

- **`load()`** — calls `FlutterGemmaPlugin.instance.createModel(gpu)`. Must be called after `FlutterGemma.initialize()`.
- **`describeImage(imageFile, prompt)`** — creates a one-shot session, feeds image + prompt, streams tokens into a string, closes session. Used for the vision-only Stage 1 pass in capture.
- The `model` getter throws if called before `load()` — callers must check `isLoaded`.

The model file (`gemma4-e4b-it-int4.task`, ~4GB) is downloaded once into the app's Documents directory via `ModelDownloadScreen`.

### agent layer — `lib/core/agent/`

**`IspyAgent`** is the main agentic loop. It wraps flutter_gemma's native function-calling API:

```
createChat(tools, systemInstruction, supportsFunctionCalls: true)
  └─ addQuery(user message or image)
  └─ loop up to 12 iterations:
       generateChatResponse()
         TextResponse       → return text (done)
         FunctionCallResponse → execute tool, feed result back
         ParallelFunctionCallResponse → execute all tools, feed all results back
```

**`FilesystemTools`** exposes 4 tools to the model:
| tool | description |
|------|-------------|
| `read_file` | read any file under the ispy root |
| `write_file` | write/create a file (creates parent dirs) |
| `list_dir` | list a directory |
| `search_files` | grep all `.md` files for a keyword |

All paths are sandboxed: `_safe()` rejects any path that escapes the base directory via `..` traversal.

**`Prompts`** holds all system and user prompt strings. Kept here so prompt changes don't touch feature code.

### filesystem layer — `lib/core/filesystem/`

The AI's memory lives at `<Documents>/` and is entirely freeform — ispy decides the structure. Two helper classes provide typed access for the app UI:

**`LogStore`** — append-only photo log.
- Directory: `<Documents>/log/<timestamp>/`
- Each entry has `photo.jpg` (written by app) and `entry.md` (written by ispy via `write_file` tool).
- `listEntries()` returns entries sorted newest-first, used by SocialScreen to count photos.

**`WikiStore`** — reads the wiki for display.
- `buildGraph()` scans all `.md` files and parses `[[link]]` syntax to build a node graph for WikiScreen.
- `readFile(path)` returns raw markdown for WikiDetailScreen.

### UI layer — `lib/features/`

| screen | responsibility |
|--------|---------------|
| `CaptureScreen` | camera preview → two-stage capture (vision pass + agent pass) |
| `ChatScreen` | message list + IspyAgent for each turn |
| `WikiScreen` | interactive graph of ispy's wiki pages |
| `WikiDetailScreen` | raw markdown for a single wiki node |
| `SocialScreen` | photo counter toward 100, locked friend feed mockup |
| `ModelDownloadScreen` | one-time model download with progress |

All screens share a background color of `Color(0xFFF5F5FA)` (light lavender-white).

`IspyTabBar` uses `IndexedStack` so all four tab screens stay alive in memory — the camera doesn't reinitialize on every tab switch.

---

## capture flow

```
user taps shutter
  └─ CameraController.takePicture()
  └─ optional: user types context
  └─ Stage 1: GemmaService.describeImage(visionOnly prompt)
       → pure observation, no character, no tools
  └─ Stage 2: IspyAgent.run(system prompt + observations + exif)
       → agent navigates wiki, writes log entry, updates wiki
  └─ done
```

Stage 1 uses a plain session (no function calls). Stage 2 uses the full agent loop with all four filesystem tools available.

---

## startup flow

```
main()
  └─ LiquidGlassWidgets.initialize()   ← warms Metal shaders
  └─ runApp(LiquidGlassWidgets.wrap(IspyApp()))

IspyApp._loadModel()
  └─ FlutterGemma.initialize()         ← one-time native init
  └─ GemmaService.modelExists()?
       no  → ModelDownloadScreen
       yes → GemmaService.load()       ← loads model onto GPU
            → IspyTabBar
```

---

## key constraints

- **GPU only** — model is loaded with `preferredBackend: gpu`. Falls back to CPU if Metal is unavailable but significantly slower.
- **Single model instance** — `GemmaService` is created once in `IspyApp` and passed down. Creating multiple instances would exceed device memory.
- **No streaming to UI** — both capture and chat use `generateChatResponse()` (full sync response) rather than the streaming async variant. This keeps the agent loop simple at the cost of no token-by-token UI updates.
- **Max 12 tool iterations** — the agent loop has a hard cap to prevent infinite loops if the model gets stuck.
- **Sandboxed filesystem** — `FilesystemTools._safe()` normalizes paths and rejects anything outside the base dir. The model cannot read arbitrary device files.
