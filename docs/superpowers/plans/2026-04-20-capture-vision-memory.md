# Capture + Vision + Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add camera/gallery photo capture, Gemma vision analysis, filesystem storage, and a memory list viewer to the existing Swift ispy app.

**Architecture:** `LLMService` is refactored to expose the loaded `LlmInference` object; `VisionService` wraps it for single-turn vision inference; `MemoryStore` persists entries as JSON + JPEG; `CaptureView` and `MemoryView` are wired together in a `TabView` via `RootView`, shown only after the model loads.

**Tech Stack:** Swift 5.9, SwiftUI, PhotosUI, MediaPipeTasksGenAI 0.10.33, FileManager JSON persistence.

---

## File Map

| Path | Action | Role |
|------|--------|------|
| `ispy/ispy/LLMService.swift` | Modify | Remove prompt run, expose `inference`, add `maxImages = 1` |
| `ispy/ispy/ContentView.swift` | Modify | `.ready` case shows `RootView(service:)` instead of response text |
| `ispy/ispy/RootView.swift` | Create | `TabView` — Capture tab + Memory tab |
| `ispy/ispy/CaptureView.swift` | Create | Camera + gallery picker, analyze, save flow |
| `ispy/ispy/CameraView.swift` | Create | `UIViewControllerRepresentable` wrapping `UIImagePickerController` |
| `ispy/ispy/VisionService.swift` | Create | Single-turn vision inference using `LlmInference.Session` |
| `ispy/ispy/MemoryStore.swift` | Create | `@Observable` — JSON index + JPEG photo files |
| `ispy/ispy/MemoryView.swift` | Create | Entry list + detail sheet |

---

## Task 1: Refactor LLMService

**Files:**
- Modify: `ispy/ispy/LLMService.swift`
- Modify: `ispy/ispy/ContentView.swift`

The current `LLMService` runs a hardcoded text prompt after loading and stores the response in `.ready(response:)`. We need it to instead expose the raw `LlmInference` object so `VisionService` can create sessions from it, and transition to `.ready` (no associated value) so `ContentView` can show `RootView`.

- [ ] **Step 1: Replace `LLMService.swift`**

```swift
import Foundation
import MediaPipeTasksGenAI

@Observable
@MainActor
final class LLMService: NSObject {
    enum State {
        case needsDownload
        case downloading(progress: Double)
        case loading
        case ready
        case error(message: String)
    }

    nonisolated static let modelFileName = "gemma-3n-E2B-it-int4.task"
    nonisolated static let modelURL = URL(string:
        "https://huggingface.co/google/gemma-3n-E2B-it-litert-preview/resolve/main/gemma-3n-E2B-it-int4.task"
    )!
    nonisolated static let hfToken = "REMOVED_HF_TOKEN"

    var state: State = .needsDownload
    private(set) var inference: LlmInference?

    private var modelPath: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.modelFileName)
    }

    func start() {
        if FileManager.default.fileExists(atPath: modelPath.path) {
            loadModel()
        }
    }

    func download() {
        state = .downloading(progress: 0)
        var request = URLRequest(url: Self.modelURL)
        request.setValue("Bearer \(Self.hfToken)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session.downloadTask(with: request).resume()
    }

    func loadModel() {
        state = .loading
        let path = modelPath.path
        Task.detached(priority: .userInitiated) {
            do {
                print("[ispy] loading model at \(path)")
                let options = LlmInference.Options(modelPath: path)
                options.maxTokens = 1024
                options.maxImages = 1
                let inference = try LlmInference(options: options)
                print("[ispy] model ready")
                await MainActor.run {
                    self.inference = inference
                    self.state = .ready
                }
            } catch {
                let msg = error.localizedDescription
                print("[ispy] load error: \(msg)")
                if msg.contains("zip") || msg.contains("archive") || msg.contains("open") {
                    try? FileManager.default.removeItem(atPath: path)
                    await MainActor.run { self.state = .needsDownload }
                } else {
                    await MainActor.run { self.state = .error(message: msg) }
                }
            }
        }
    }
}

extension LLMService: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var r = request
        if r.url?.host?.contains("huggingface.co") == true {
            r.setValue("Bearer \(LLMService.hfToken)", forHTTPHeaderField: "Authorization")
        } else {
            r.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(r)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let p = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        Task { @MainActor in self.state = .downloading(progress: p) }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            Task { @MainActor in
                self.state = .error(message: "HTTP \(http.statusCode) — check token and model access")
            }
            return
        }
        let dest = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(LLMService.modelFileName)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor in self.loadModel() }
        } catch {
            Task { @MainActor in
                self.state = .error(message: "Save failed: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            Task { @MainActor in
                self.state = .error(message: "Download failed: \(error.localizedDescription)")
            }
        }
    }
}
```

- [ ] **Step 2: Replace `ContentView.swift`**

```swift
import SwiftUI

struct ContentView: View {
    @State private var service = LLMService()

    var body: some View {
        switch service.state {
        case .needsDownload:
            VStack(spacing: 24) {
                Text("gemma-3n-E2B (~2 GB)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Download Model") { service.download() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

        case .downloading(let p):
            VStack(spacing: 12) {
                ProgressView(value: p).padding(.horizontal)
                Text("\(Int(p * 100))%")
            }
            .padding()

        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading model...")
            }

        case .ready:
            RootView(service: service)

        case .error(let message):
            VStack(spacing: 16) {
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Retry") { service.start() }
            }
            .padding()
        }
    }
}
```

Note: `RootView` doesn't exist yet — this will cause a compile error until Task 7. That's fine; build check happens after Task 7.

- [ ] **Step 3: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/ispy/LLMService.swift ispy/ispy/ContentView.swift
git commit -m "refactor: LLMService exposes inference object, removes hardcoded prompt"
```

---

## Task 2: Camera and photo library permissions

**Files:**
- Modify: `ispy/ispy/Info.plist` (create if it doesn't exist)

Privacy permission strings must be present or the app crashes when requesting camera/photo access.

- [ ] **Step 1: Check if Info.plist exists**

```bash
ls /Users/dima/Projects/ispy/ispy/ispy/Info.plist 2>/dev/null || echo "not found"
```

- [ ] **Step 2a: If Info.plist does NOT exist — add keys via Xcode**

In Xcode: click `ispy` project → `ispy` target → **Info** tab → click **+** on any row and add:
- Key: `Privacy - Camera Usage Description` → Value: `ispy uses the camera to capture moments`
- Key: `Privacy - Photo Library Usage Description` → Value: `ispy reads your photo library to analyze images`

- [ ] **Step 2b: If Info.plist DOES exist — add keys directly**

Add inside the `<dict>` tag:

```xml
<key>NSCameraUsageDescription</key>
<string>ispy uses the camera to capture moments</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>ispy reads your photo library to analyze images</string>
```

- [ ] **Step 3: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/ispy/Info.plist
git commit -m "feat: add camera and photo library permission strings"
```

---

## Task 3: MemoryStore

**Files:**
- Create: `ispy/ispy/MemoryStore.swift`

Owns all persistence: JSON index of entries + JPEG photos in `Documents/memory/`.

- [ ] **Step 1: Create `ispy/ispy/MemoryStore.swift`**

```swift
import Foundation
import UIKit

struct MemoryEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let description: String
    let photoFilename: String
}

enum MemoryError: Error {
    case invalidImage
}

@Observable
final class MemoryStore {
    private(set) var entries: [MemoryEntry] = []

    private let photosDir: URL
    private let indexURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let memoryDir = docs.appendingPathComponent("memory")
        photosDir = memoryDir.appendingPathComponent("photos")
        indexURL = memoryDir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        load()
    }

    func save(image: UIImage, description: String) throws {
        let id = UUID()
        let filename = "\(id.uuidString).jpg"
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            throw MemoryError.invalidImage
        }
        try data.write(to: photosDir.appendingPathComponent(filename))
        let entry = MemoryEntry(id: id, timestamp: Date(), description: description, photoFilename: filename)
        entries.append(entry)
        try writeIndex()
    }

    func photoURL(for entry: MemoryEntry) -> URL {
        photosDir.appendingPathComponent(entry.photoFilename)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        entries = (try? JSONDecoder().decode([MemoryEntry].self, from: data)) ?? []
    }

    private func writeIndex() throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: indexURL)
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/ispy/MemoryStore.swift
git commit -m "feat: add MemoryStore — JSON index + JPEG photo persistence"
```

---

## Task 4: VisionService + CameraView

**Files:**
- Create: `ispy/ispy/VisionService.swift`
- Create: `ispy/ispy/CameraView.swift`

- [ ] **Step 1: Create `ispy/ispy/VisionService.swift`**

```swift
import Foundation
import UIKit
import MediaPipeTasksGenAI

enum VisionError: Error, LocalizedError {
    case invalidImage
    case modelNotReady

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Could not process image"
        case .modelNotReady: return "Model not loaded"
        }
    }
}

final class VisionService {
    nonisolated static let prompt = "You are ispy, a personal AI witness. Describe what you see in this photo in 2-3 sentences. Be specific about people, objects, places, and mood."

    private let inference: LlmInference

    init(inference: LlmInference) {
        self.inference = inference
    }

    func describe(image: UIImage) throws -> String {
        let sessionOpts = LlmInference.Session.Options()
        sessionOpts.topk = 40
        sessionOpts.temperature = 0.8
        sessionOpts.enableVisionModality = true
        let session = try LlmInference.Session(llmInference: inference, options: sessionOpts)
        guard let cgImage = image.cgImage else { throw VisionError.invalidImage }
        try session.addImage(image: cgImage)
        try session.addQueryChunk(inputText: Self.prompt)
        return try session.generateResponse()
    }
}
```

- [ ] **Step 2: Create `ispy/ispy/CameraView.swift`**

```swift
import SwiftUI
import UIKit

struct CameraView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let dismiss: DismissAction

        init(onCapture: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/ispy/VisionService.swift ispy/ispy/CameraView.swift
git commit -m "feat: add VisionService and CameraView"
```

---

## Task 5: CaptureView

**Files:**
- Create: `ispy/ispy/CaptureView.swift`

The main capture flow: select photo → analyze → save.

- [ ] **Step 1: Create `ispy/ispy/CaptureView.swift`**

```swift
import SwiftUI
import PhotosUI

struct CaptureView: View {
    let service: LLMService
    let memoryStore: MemoryStore

    @State private var selectedImage: UIImage?
    @State private var description: String?
    @State private var isAnalyzing = false
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var saved = false

    private func makeVisionService() -> VisionService? {
        guard let inference = service.inference else { return nil }
        return VisionService(inference: inference)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image = selectedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 300)
                        .cornerRadius(8)

                    if isAnalyzing {
                        ProgressView("Analyzing...")
                    } else if let desc = description {
                        ScrollView {
                            Text(desc).padding(.horizontal)
                        }
                        .frame(maxHeight: 150)

                        if saved {
                            Text("Saved ✓").foregroundStyle(.green)
                        } else {
                            HStack(spacing: 16) {
                                Button("Save") { saveEntry(image: image, description: desc) }
                                    .buttonStyle(.borderedProminent)
                                Button("Clear") { clear() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    } else {
                        HStack(spacing: 16) {
                            Button("Analyze") { analyze(image: image) }
                                .buttonStyle(.borderedProminent)
                            Button("Clear") { clear() }
                                .buttonStyle(.bordered)
                        }
                    }
                } else {
                    Spacer()
                    HStack(spacing: 32) {
                        Button {
                            showCamera = true
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "camera.fill").font(.largeTitle)
                                Text("Camera").font(.caption)
                            }
                        }

                        PhotosPicker(selection: $photoItem, matching: .images) {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.fill").font(.largeTitle)
                                Text("Gallery").font(.caption)
                            }
                        }
                    }
                    Spacer()
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .navigationTitle("Capture")
            .fullScreenCover(isPresented: $showCamera) {
                CameraView { image in
                    selectedImage = image
                    description = nil
                }
            }
            .onChange(of: photoItem) { _, newItem in
                Task {
                    guard let newItem else { return }
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        selectedImage = image
                        description = nil
                        saved = false
                    }
                }
            }
        }
    }

    private func analyze(image: UIImage) {
        guard let vision = makeVisionService() else {
            errorMessage = "Model not ready"
            return
        }
        isAnalyzing = true
        errorMessage = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try vision.describe(image: image)
                }.value
                description = result
            } catch {
                errorMessage = error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    private func saveEntry(image: UIImage, description: String) {
        do {
            try memoryStore.save(image: image, description: description)
            saved = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clear() {
        selectedImage = nil
        description = nil
        errorMessage = nil
        photoItem = nil
        saved = false
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/ispy/CaptureView.swift
git commit -m "feat: add CaptureView — camera, gallery, analyze, save"
```

---

## Task 6: MemoryView

**Files:**
- Create: `ispy/ispy/MemoryView.swift`

Entry list with timestamp + first line of description; tap opens full detail sheet.

- [ ] **Step 1: Create `ispy/ispy/MemoryView.swift`**

```swift
import SwiftUI

struct MemoryView: View {
    let memoryStore: MemoryStore
    @State private var selectedEntry: MemoryEntry?

    var body: some View {
        NavigationStack {
            Group {
                if memoryStore.entries.isEmpty {
                    ContentUnavailableView(
                        "No memories yet",
                        systemImage: "brain",
                        description: Text("Capture and analyze a photo to create your first memory.")
                    )
                } else {
                    List(memoryStore.entries.reversed()) { entry in
                        Button { selectedEntry = entry } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.timestamp, format: .dateTime.day().month().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(entry.description.components(separatedBy: .newlines).first ?? "")
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Memory")
            .sheet(item: $selectedEntry) { entry in
                MemoryDetailView(entry: entry, photoURL: memoryStore.photoURL(for: entry))
            }
        }
    }
}

struct MemoryDetailView: View {
    let entry: MemoryEntry
    let photoURL: URL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let image = UIImage(contentsOfFile: photoURL.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.timestamp, format: .dateTime.weekday().day().month().year().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.description)
                }
                .padding(.horizontal)
            }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/ispy/MemoryView.swift
git commit -m "feat: add MemoryView — entry list and detail sheet"
```

---

## Task 7: RootView + build verification

**Files:**
- Create: `ispy/ispy/RootView.swift`

`TabView` wiring `CaptureView` and `MemoryView`. After this task, the entire app compiles.

- [ ] **Step 1: Create `ispy/ispy/RootView.swift`**

```swift
import SwiftUI

struct RootView: View {
    let service: LLMService
    @State private var memoryStore = MemoryStore()

    var body: some View {
        TabView {
            CaptureView(service: service, memoryStore: memoryStore)
                .tabItem { Label("Capture", systemImage: "camera.fill") }
            MemoryView(memoryStore: memoryStore)
                .tabItem { Label("Memory", systemImage: "brain") }
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/dima/Projects/ispy/ispy
xcodebuild -workspace ispy.xcworkspace -scheme ispy -destination 'generic/platform=iOS' -quiet build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

If there are compiler errors, fix them before committing. Common issues:
- `RootView` not found → make sure the file is in `ispy/ispy/` directory (auto-discovered by Xcode 16)
- `DismissAction` in `CameraView` — if this causes issues, replace `@Environment(\.dismiss) private var dismiss` in `CameraView` with passing a binding `isPresented: Binding<Bool>` instead

- [ ] **Step 3: Run on device and verify end-to-end**

Connect iPhone. In Xcode: select device → ⌘R.

Expected flow:
1. Model loads → two tabs appear: Capture and Memory
2. Capture tab: Camera and Gallery buttons visible
3. Tap Gallery → photo picker opens → select a photo → photo appears
4. Tap Analyze → spinner → description appears (takes ~10-30s)
5. Tap Save → "Saved ✓" confirmation
6. Switch to Memory tab → entry appears with timestamp and first line
7. Tap entry → sheet opens with full photo + description

- [ ] **Step 4: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/ispy/RootView.swift
git commit -m "feat: add RootView TabView — capture + vision + memory complete"
```
