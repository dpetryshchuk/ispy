# ispy: Capture + Vision + Memory Design Spec

## Goal

Add photo capture (camera + gallery), Gemma vision analysis, filesystem storage, and a memory viewer to the existing Swift ispy app. This is the core capture loop — the foundation for the agent and wiki features that come later.

## Current State

Three Swift files: `ispyApp.swift`, `ContentView.swift`, `LLMService.swift`. Gemma E2B loads via MediaPipeTasksGenAI and answers a hardcoded text prompt. No camera, no storage, no tabs.

## New Files

| File | Responsibility |
|------|---------------|
| `RootView.swift` | Replaces `ContentView` as root. `TabView` with Capture and Memory tabs. Only rendered after model is ready. |
| `CaptureView.swift` | Camera button + gallery picker, photo preview, Analyze button, result display, Save button |
| `VisionService.swift` | Takes `UIImage`, runs single-turn vision inference via `LLMService`, returns description `String` |
| `MemoryStore.swift` | Saves/loads entries. JSON index + JPEG files on disk. |
| `MemoryView.swift` | List of entries (timestamp + first line). Tap → sheet with full photo + description. |

## Architecture

```
RootView (TabView)
├── CaptureView
│     └── VisionService → LLMService.model
└── MemoryView
      └── MemoryStore
```

`LLMService` is unchanged except: expose `model: LlmInference` as a computed property so `VisionService` can use it directly. All model state management stays in `LLMService`.

## Data Flow

1. User taps camera or gallery → `UIImagePickerController` / `PHPickerViewController`
2. Photo selected → shown in preview
3. User taps "Analyze" → `VisionService.describe(image:)` called
4. `VisionService` creates a fresh `LlmInference.Session` with `enableVisionModality: true`, adds image + prompt, calls `generateResponse()`
5. Description returned → shown below photo
6. User taps "Save" → `MemoryStore.save(image:description:)` writes JPEG + appends to index
7. Memory tab shows updated list

## Storage Layout

```
Documents/
  memory/
    index.json          — [{id, timestamp, description, photoFilename}]
    photos/
      <uuid>.jpg
```

`index.json` is an array of `MemoryEntry` structs, appended on each save. Photos are stored as JPEG at 0.8 quality.

## MemoryEntry

```swift
struct MemoryEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let description: String
    let photoFilename: String   // just filename, not full path
}
```

## VisionService

Single method, no state:

```swift
final class VisionService {
    private let llm: LLMService
    func describe(image: UIImage) async throws -> String
}
```

Creates a new `LlmInference.Session` per call. Prompt: `"You are ispy, a personal AI witness. Describe what you see in this photo in 2-3 sentences. Be specific about people, objects, places, and mood."` Converts `UIImage` to JPEG `Data`, passes as `MPImage` or raw bytes per MediaPipe API.

## ContentView Changes

`ContentView` becomes the loading/download/error screen only. Once `LLMService.state == .ready`, it hands off to `RootView`. `RootView` is only shown when the model is loaded.

## Permissions

Add to `Info.plist`:
- `NSCameraUsageDescription` — "ispy uses the camera to capture moments"
- `NSPhotoLibraryUsageDescription` — "ispy reads your photo library to analyze images"

## Out of Scope

- Agent loop / tool calling
- Wiki creation / cross-linking
- Editing or deleting entries
- Search
