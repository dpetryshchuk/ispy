# ispy Swift Rewrite — Design Spec

## Goal

Replace the Flutter app entirely with a minimal native Swift/SwiftUI app that downloads Gemma 3n-E4B, loads it via MediaPipe's LlmInference SDK, sends a hardcoded prompt, and displays the response. Nothing else.

## Why

The Flutter `flutter_gemma` plugin crashes on iOS with `EXC_BAD_ACCESS (code=50)` — `KERN_CODESIGN_ERROR` — because the LiteRT GPU delegate JIT-compiles Metal shaders, which requires the `dynamic-codesigning` entitlement. Personal dev accounts don't have it. The native Swift `MediaPipeTasksGenAI` SDK's CPU path does not require this entitlement. Going native removes the plugin layer entirely.

## Architecture

Three Swift source files. No more.

```
ispy/
  ispyApp.swift       — @main, WindowGroup { ContentView() }
  ContentView.swift   — SwiftUI view, switches on LLMService.state
  LLMService.swift    — @Observable class, owns download + load + infer
Podfile               — MediaPipeTasksGenAI, MediaPipeTasksGenAIC
```

### LLMService

`@Observable` class with a single `state: State` property. States:

```
enum State {
  case needsDownload
  case downloading(progress: Double)   // 0.0–1.0
  case loading
  case ready(response: String)
  case error(message: String)
}
```

**Download:** `URLSession` with a `downloadTask` to stream `gemma-3n-E4B-it-int4.task` from HuggingFace to the app's Documents directory. Authorization header: `Bearer REMOVED_HF_TOKEN`. Progress via `URLSessionDownloadDelegate`.

**Load:** `LlmInference.Options(modelPath: path)` with `maxTokens = 1024`. Wrapped in `Task { }` off main thread to avoid blocking UI.

**Infer:** `LlmInference.Session` → `session.addQueryChunk(inputText: prompt)` → `session.generateResponse()`. Hardcoded prompt: `"Describe yourself in one sentence."`. Fires automatically once load succeeds.

### ContentView

Plain `VStack` switch on `service.state`:
- `.needsDownload` — "Download Model" button
- `.downloading(let p)` — `ProgressView(value: p)` + percentage label
- `.loading` — `ProgressView()` spinner + "Loading model..."
- `.ready(let r)` — response text
- `.error(let m)` — red error text + retry button

No navigation, no tabs, no styling beyond what SwiftUI provides by default.

## Model

| Field | Value |
|---|---|
| File | `gemma-3n-E4B-it-int4.task` |
| Repo | `google/gemma-3n-E4B-it-litert-preview` |
| URL | `https://huggingface.co/google/gemma-3n-E4B-it-litert-preview/resolve/main/gemma-3n-E4B-it-int4.task` |
| Token | hardcoded `REMOVED_HF_TOKEN` |
| Destination | `FileManager.default.urls(for: .documentDirectory)[0]/gemma-3n-E4B-it-int4.task` |

## What Gets Deleted

Everything Flutter:
- `lib/` — all Dart source
- `pubspec.yaml`, `pubspec.lock`
- `android/`
- `references/` (Flutter reference repos)
- `ios/` — replaced with fresh Xcode project

## Dependencies

CocoaPods only:
```ruby
target 'ispy' do
  use_frameworks!
  pod 'MediaPipeTasksGenAI'
  pod 'MediaPipeTasksGenAIC'
end
```

## Out of Scope

Camera, vision, filesystem, agent loop, log viewer, tabs — all deferred until this works.
