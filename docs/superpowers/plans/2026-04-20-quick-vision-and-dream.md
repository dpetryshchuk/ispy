# Quick Vision + Dream Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the crashing MediaPipe vision inference with Apple's Vision framework for instant on-device analysis, and add a "Dream" button that loads E2B on-demand as a text-only model to synthesize a rich description from the quick labels — then unloads it to free 2 GB of memory.

**Architecture:** `QuickVisionService` uses `VNClassifyImageRequest` + `VNRecognizeTextRequest` to produce labels and OCR text in ~100ms with zero memory cost. The "Analyze" button calls this immediately. After saving, a "Dream" button triggers `DreamService`, which asks `LLMService` to download/load E2B if needed, runs a text-only Gemma session using the quick labels as context, saves the result to `MemoryEntry.dreamDescription`, then calls `LLMService.unloadModel()` to reclaim 2 GB. `LLMService` gains an `.idle` state (model on disk, not in memory) and `unloadModel()`. `ContentView` is simplified to go straight to `RootView`, which now owns `LLMService`.

**Tech Stack:** Swift 5.9, SwiftUI, Vision framework (iOS 17+), MediaPipeTasksGenAI 0.10.33 (text-only sessions only).

---

## File Map

| File | Action | Role |
|------|--------|------|
| `ispy/ispy/QuickVisionService.swift` | Create | Apple Vision labels + OCR → `QuickAnalysis` struct |
| `ispy/ispy/DreamService.swift` | Create | Gemma text-only session using quick labels as prompt context |
| `ispy/ispy/VisionService.swift` | Delete | Was MediaPipe vision — caused `bad_alloc`, no longer used |
| `ispy/ispy/LLMService.swift` | Modify | Add `.idle` state, `unloadModel()`, fix `start()` to not auto-load |
| `ispy/ispy/ContentView.swift` | Modify | Remove model-gating, go straight to `RootView()` |
| `ispy/ispy/RootView.swift` | Modify | Create `LLMService` internally (no longer a param), call `start()` on appear |
| `ispy/ispy/MemoryStore.swift` | Modify | Add `dreamDescription: String?` to `MemoryEntry`, add `updateDream()` |
| `ispy/ispy/CaptureView.swift` | Modify | Analyze → QuickVisionService; Dream button → DreamService flow |
| `ispy/ispy/MemoryView.swift` | Modify | Show dream description section in `MemoryDetailView` |

---

## Task 1: QuickVisionService

**Files:**
- Create: `ispy/ispy/QuickVisionService.swift`

Instant on-device image analysis using Apple's Vision framework. No LLM, no memory cost, runs in ~100ms.

- [ ] **Step 1: Create `ispy/ispy/QuickVisionService.swift`**

```swift
import Vision
import UIKit

struct QuickAnalysis {
    let labels: [String]
    let ocrText: String

    var formattedDescription: String {
        var parts: [String] = []
        if !labels.isEmpty {
            parts.append("Scene: \(labels.prefix(5).joined(separator: ", "))")
        }
        if !ocrText.isEmpty {
            parts.append("Text visible: \(ocrText)")
        }
        return parts.isEmpty ? "No details detected." : parts.joined(separator: ". ") + "."
    }
}

enum QuickVisionError: Error, LocalizedError {
    case invalidImage
    case analysisFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Could not read image data"
        case .analysisFailure(let msg): return msg
        }
    }
}

final class QuickVisionService {
    func analyze(image: UIImage) throws -> QuickAnalysis {
        guard let cgImage = image.cgImage else { throw QuickVisionError.invalidImage }

        var labels: [String] = []
        var ocrText = ""
        var classifyError: Error?
        var ocrError: Error?

        let group = DispatchGroup()

        // Classification
        group.enter()
        let classifyRequest = VNClassifyImageRequest { request, error in
            defer { group.leave() }
            if let error { classifyError = error; return }
            labels = (request.results as? [VNClassificationObservation])?
                .filter { $0.confidence > 0.3 }
                .prefix(8)
                .map { $0.identifier }
                ?? []
        }

        // OCR
        group.enter()
        let ocrRequest = VNRecognizeTextRequest { request, error in
            defer { group.leave() }
            if let error { ocrError = error; return }
            ocrText = (request.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
                ?? ""
        }
        ocrRequest.recognitionLevel = .accurate
        ocrRequest.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([classifyRequest, ocrRequest])
        group.wait()

        if let err = classifyError { throw QuickVisionError.analysisFailure(err.localizedDescription) }
        _ = ocrError // OCR failure is non-fatal

        return QuickAnalysis(labels: labels, ocrText: ocrText)
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/ispy/QuickVisionService.swift
git commit -m "feat: add QuickVisionService — Apple Vision labels + OCR"
```

---

## Task 2: LLMService — add .idle state and unloadModel()

**Files:**
- Modify: `ispy/ispy/LLMService.swift`

Add an `.idle` state (model file on disk, not loaded into memory) and `unloadModel()` so Dream can release 2 GB after finishing. Change `start()` to set `.idle` instead of auto-loading.

- [ ] **Step 1: Replace `ispy/ispy/LLMService.swift`**

```swift
import Foundation
import MediaPipeTasksGenAI

@Observable
@MainActor
final class LLMService: NSObject {
    enum State {
        case needsDownload
        case downloading(progress: Double)
        case idle           // model on disk, not in memory
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

    var modelIsDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelPath.path)
    }

    func start() {
        state = modelIsDownloaded ? .idle : .needsDownload
    }

    func download() {
        state = .downloading(progress: 0)
        var request = URLRequest(url: Self.modelURL)
        request.setValue("Bearer \(Self.hfToken)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session.downloadTask(with: request).resume()
    }

    func loadModel() {
        guard case .idle = state else { return }
        state = .loading
        let path = modelPath.path
        Task.detached(priority: .userInitiated) {
            do {
                print("[ispy] loading model at \(path)")
                let options = LlmInference.Options(modelPath: path)
                options.maxTokens = 1024
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

    func unloadModel() {
        inference = nil
        state = modelIsDownloaded ? .idle : .needsDownload
        print("[ispy] model unloaded")
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
            Task { @MainActor in self.state = .idle }
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

Note: `maxImages` is removed — Dream uses text-only sessions, no vision modality needed. `loadModel()` now guards against being called when not `.idle`.

- [ ] **Step 2: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/ispy/LLMService.swift
git commit -m "refactor: LLMService adds .idle state and unloadModel()"
```

---

## Task 3: DreamService

**Files:**
- Create: `ispy/ispy/DreamService.swift`

Text-only Gemma session that generates a rich description from quick-vision labels. No `enableVisionModality` — this is what avoids the `bad_alloc` crash.

- [ ] **Step 1: Create `ispy/ispy/DreamService.swift`**

```swift
import Foundation
import MediaPipeTasksGenAI

final class DreamService {
    private let inference: LlmInference

    init(inference: LlmInference) {
        self.inference = inference
    }

    func describe(quickDescription: String) throws -> String {
        let sessionOpts = LlmInference.Session.Options()
        sessionOpts.topk = 40
        sessionOpts.temperature = 0.9
        let session = try LlmInference.Session(llmInference: inference, options: sessionOpts)
        let prompt = """
        You are ispy, a personal AI witness. A photo was captured and quick on-device analysis detected: \(quickDescription)

        Write a vivid, specific 2-3 sentence description of this moment. Focus on what it reveals about the person, place, or atmosphere. Be concrete, not generic.
        """
        try session.addQueryChunk(inputText: prompt)
        return try session.generateResponse()
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/ispy/DreamService.swift
git commit -m "feat: add DreamService — text-only Gemma session for rich descriptions"
```

---

## Task 4: MemoryStore — add dreamDescription

**Files:**
- Modify: `ispy/ispy/MemoryStore.swift`

Add `dreamDescription: String?` to `MemoryEntry` and an `updateDream()` method so CaptureView can enrich a saved entry after dream completes.

- [ ] **Step 1: Replace `ispy/ispy/MemoryStore.swift`**

```swift
import Foundation
import UIKit

struct MemoryEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    var description: String
    let photoFilename: String
    var dreamDescription: String?
}

enum MemoryError: Error {
    case invalidImage
    case entryNotFound
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

    func updateDream(id: UUID, dreamDescription: String) throws {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else {
            throw MemoryError.entryNotFound
        }
        entries[idx].dreamDescription = dreamDescription
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

Note: `description` and `dreamDescription` are now `var` so `updateDream()` can mutate them. Existing entries decode fine — `dreamDescription` is optional so old JSON without that key just gets `nil`.

- [ ] **Step 2: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/ispy/MemoryStore.swift
git commit -m "feat: MemoryEntry gains dreamDescription, MemoryStore gains updateDream()"
```

---

## Task 5: ContentView + RootView — remove model gate

**Files:**
- Modify: `ispy/ispy/ContentView.swift`
- Modify: `ispy/ispy/RootView.swift`

App now goes straight to `RootView`. `RootView` owns `LLMService` and calls `start()` on appear. The model-gating UI (download button, progress bar) is gone from `ContentView` — that state is handled inline in `CaptureView`'s Dream flow.

- [ ] **Step 1: Replace `ispy/ispy/ContentView.swift`**

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        RootView()
    }
}
```

- [ ] **Step 2: Replace `ispy/ispy/RootView.swift`**

```swift
import SwiftUI

struct RootView: View {
    @State private var llmService = LLMService()
    @State private var memoryStore = MemoryStore()

    var body: some View {
        TabView {
            CaptureView(llmService: llmService, memoryStore: memoryStore)
                .tabItem { Label("Capture", systemImage: "camera.fill") }
            MemoryView(memoryStore: memoryStore)
                .tabItem { Label("Memory", systemImage: "brain") }
        }
        .onAppear { llmService.start() }
    }
}
```

- [ ] **Step 3: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/ispy/ContentView.swift ispy/ispy/RootView.swift
git commit -m "refactor: ContentView goes straight to RootView, RootView owns LLMService"
```

---

## Task 6: CaptureView — QuickVisionService + Dream button

**Files:**
- Modify: `ispy/ispy/CaptureView.swift`

Replace MediaPipe vision with `QuickVisionService` for the Analyze button. Add Dream button that appears after save, drives the LLM download/load/infer/unload cycle by observing `llmService.state`.

- [ ] **Step 1: Replace `ispy/ispy/CaptureView.swift`**

```swift
import SwiftUI
import PhotosUI

struct CaptureView: View {
    let llmService: LLMService
    let memoryStore: MemoryStore

    @State private var selectedImage: UIImage?
    @State private var quickDescription: String?
    @State private var dreamDescription: String?
    @State private var isAnalyzing = false
    @State private var isDreaming = false
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var savedEntryID: UUID?

    private let quickVision = QuickVisionService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image = selectedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .cornerRadius(8)

                    if isAnalyzing {
                        ProgressView("Analyzing...")
                    } else if isDreaming {
                        dreamProgressView
                    } else if let dream = dreamDescription {
                        dreamResultView(dream: dream)
                    } else if let quick = quickDescription {
                        quickResultView(image: image, quick: quick)
                    } else {
                        analyzeButtons(image: image)
                    }
                } else {
                    Spacer()
                    pickerButtons
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
                    reset()
                }
            }
            .onChange(of: photoItem) { _, newItem in
                Task {
                    guard let newItem else { return }
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        selectedImage = image
                        reset()
                    }
                }
            }
            .onChange(of: llmService.state) { _, newState in
                guard isDreaming else { return }
                switch newState {
                case .idle:
                    llmService.loadModel()
                case .ready:
                    runDreamInference()
                case .error(let msg):
                    errorMessage = msg
                    isDreaming = false
                default:
                    break
                }
            }
        }
    }

    // MARK: - Subviews

    private var pickerButtons: some View {
        HStack(spacing: 32) {
            Button { showCamera = true } label: {
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
    }

    private func analyzeButtons(image: UIImage) -> some View {
        HStack(spacing: 16) {
            Button("Analyze") { analyze(image: image) }
                .buttonStyle(.borderedProminent)
            Button("Clear") { clearAll() }
                .buttonStyle(.bordered)
        }
    }

    private func quickResultView(image: UIImage, quick: String) -> some View {
        VStack(spacing: 12) {
            ScrollView {
                Text(quick).padding(.horizontal)
            }
            .frame(maxHeight: 120)

            if savedEntryID != nil {
                HStack(spacing: 16) {
                    Button("Dream") { startDream() }
                        .buttonStyle(.borderedProminent)
                    Button("Clear") { clearAll() }
                        .buttonStyle(.bordered)
                }
                Text("Saved ✓").foregroundStyle(.green).font(.caption)
            } else {
                HStack(spacing: 16) {
                    Button("Save") { saveEntry(image: image, description: quick) }
                        .buttonStyle(.borderedProminent)
                    Button("Clear") { clearAll() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var dreamProgressView: some View {
        VStack(spacing: 12) {
            switch llmService.state {
            case .needsDownload, .idle:
                ProgressView("Preparing dream...")
            case .downloading(let p):
                VStack(spacing: 8) {
                    ProgressView(value: p).padding(.horizontal)
                    Text("Downloading model \(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
                }
            case .loading:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading model...").font(.caption).foregroundStyle(.secondary)
                }
            case .ready:
                ProgressView("Dreaming...")
            case .error(let msg):
                Text(msg).foregroundStyle(.red).font(.caption)
            }
        }
    }

    private func dreamResultView(dream: String) -> some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dream").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(dream).padding(.horizontal)
                }
                .frame(maxHeight: 150)
            }
            Button("Clear") { clearAll() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Actions

    private func analyze(image: UIImage) {
        isAnalyzing = true
        errorMessage = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try self.quickVision.analyze(image: image)
                }.value
                quickDescription = result.formattedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    private func saveEntry(image: UIImage, description: String) {
        do {
            try memoryStore.save(image: image, description: description)
            savedEntryID = memoryStore.entries.last?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startDream() {
        isDreaming = true
        errorMessage = nil
        switch llmService.state {
        case .needsDownload:
            llmService.download()
        case .idle:
            llmService.loadModel()
        case .ready:
            runDreamInference()
        default:
            break
        }
    }

    private func runDreamInference() {
        guard let inference = llmService.inference,
              let quick = quickDescription else { return }
        let svc = DreamService(inference: inference)
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try svc.describe(quickDescription: quick)
                }.value
                if let entryID = savedEntryID {
                    try? memoryStore.updateDream(id: entryID, dreamDescription: result)
                }
                dreamDescription = result
                llmService.unloadModel()
            } catch {
                errorMessage = error.localizedDescription
            }
            isDreaming = false
        }
    }

    private func reset() {
        quickDescription = nil
        dreamDescription = nil
        errorMessage = nil
        photoItem = nil
        savedEntryID = nil
    }

    private func clearAll() {
        selectedImage = nil
        reset()
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/ispy/CaptureView.swift
git commit -m "feat: CaptureView uses QuickVisionService + Dream button"
```

---

## Task 7: MemoryView — show dream description

**Files:**
- Modify: `ispy/ispy/MemoryView.swift`

Show `dreamDescription` as a separate section in the detail sheet. Entries that haven't been dreamed show nothing extra.

- [ ] **Step 1: Replace `ispy/ispy/MemoryView.swift`**

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
                                HStack {
                                    Text(entry.timestamp, format: .dateTime.day().month().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if entry.dreamDescription != nil {
                                        Image(systemName: "sparkles")
                                            .font(.caption2)
                                            .foregroundStyle(.purple)
                                    }
                                }
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

                if let dream = entry.dreamDescription {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Dream", systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.purple)
                        Text(dream)
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/ispy/MemoryView.swift
git commit -m "feat: MemoryView shows dream description with sparkle indicator"
```

---

## Task 8: Delete VisionService + build verification

**Files:**
- Delete: `ispy/ispy/VisionService.swift`

The old MediaPipe vision service is replaced entirely by `QuickVisionService`. Deleting it removes the `bad_alloc` crash path and dead code.

- [ ] **Step 1: Delete VisionService.swift**

```bash
cd /Users/dima/Projects/ispy
git rm ispy/ispy/VisionService.swift
git commit -m "chore: remove VisionService (replaced by QuickVisionService)"
```

- [ ] **Step 2: Build**

```bash
cd /Users/dima/Projects/ispy/ispy
xcodebuild -workspace ispy.xcworkspace -scheme ispy -destination 'generic/platform=iOS' -quiet build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`

Common errors to fix:
- `VisionService` referenced somewhere → search with `grep -r "VisionService" ispy/ispy/` and remove
- `service` vs `llmService` param name mismatch in `CaptureView` → check the `let llmService: LLMService` property name is used consistently

- [ ] **Step 3: Commit if any fixes were needed**

```bash
cd /Users/dima/Projects/ispy
git add -A
git commit -m "fix: build errors after VisionService removal"
```
