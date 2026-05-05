# ispy Swift Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Flutter app with a minimal native Swift/SwiftUI app that downloads Gemma 3n-E4B, loads it via MediaPipe, sends a hardcoded prompt, and shows the response.

**Architecture:** `LLMService` (`@Observable @MainActor`) owns all model state and drives a SwiftUI `ContentView` that switches on a 5-case enum. Heavy inference runs in a `Task.detached` block off the main thread.

**Tech Stack:** Swift 5.9+, SwiftUI, iOS 17+, MediaPipeTasksGenAI (CocoaPods), URLSession for download.

---

## File Map

| Path | Role |
|------|------|
| `ispy/ispyApp.swift` | `@main` entry, `WindowGroup { ContentView() }` |
| `ispy/LLMService.swift` | Download + load + infer, `@Observable @MainActor` |
| `ispy/ContentView.swift` | SwiftUI view, switches on `service.state` |
| `Podfile` | Declares `MediaPipeTasksGenAI` + `MediaPipeTasksGenAIC` |

---

## Task 1: Delete Flutter, create Xcode project

**Files:**
- Delete: `lib/`, `pubspec.yaml`, `pubspec.lock`, `android/`, `references/`, `ios/`, `test/`
- Create: `ispy.xcodeproj` (via Xcode GUI — see steps below)

- [ ] **Step 1: Delete Flutter files**

```bash
cd /Users/dima/Projects/ispy
rm -rf lib android references test pubspec.yaml pubspec.lock .flutter-plugins .flutter-plugins-dependencies
```

- [ ] **Step 2: Delete the Flutter iOS folder**

```bash
rm -rf ios
```

- [ ] **Step 3: Create new Xcode project**

Open Xcode. Choose **File → New → Project**.
- Platform: **iOS**
- Template: **App**
- Click **Next**

Fill in:
- Product Name: `ispy`
- Team: your personal team
- Organization Identifier: `com.dima`
- Bundle Identifier: `com.dima.ispy`
- Interface: **SwiftUI**
- Language: **Swift**
- Uncheck "Include Tests"

Click **Next**, then **Save** — navigate to `/Users/dima/Projects/ispy/` and click **Create**. Xcode creates `ispy.xcodeproj` and `ispy/` subfolder at that location.

- [ ] **Step 4: Set deployment target to iOS 17.0**

In Xcode: click the `ispy` project in the navigator → `ispy` target → **General** tab → set **Minimum Deployments** to `iOS 17.0`.

- [ ] **Step 5: Verify build succeeds with the generated files**

In Xcode: Product → Build (`⌘B`). Expected: Build Succeeded with the default "Hello, world!" app.

- [ ] **Step 6: Commit**

```bash
cd /Users/dima/Projects/ispy
git add -A
git commit -m "chore: delete Flutter, scaffold native Swift iOS project"
```

---

## Task 2: CocoaPods setup

**Files:**
- Create: `/Users/dima/Projects/ispy/Podfile`

- [ ] **Step 1: Write the Podfile**

Create `/Users/dima/Projects/ispy/Podfile` with exactly this content:

```ruby
platform :ios, '17.0'

target 'ispy' do
  use_frameworks!
  pod 'MediaPipeTasksGenAI'
  pod 'MediaPipeTasksGenAIC'
end
```

- [ ] **Step 2: Install pods**

```bash
cd /Users/dima/Projects/ispy
pod install
```

Expected output ends with:
```
Pod installation complete! There are 2 dependencies from the Podfile and X total pods installed.
```

This creates `ispy.xcworkspace`. **From this point on, always open `ispy.xcworkspace`, never `ispy.xcodeproj`.**

- [ ] **Step 3: Close ispy.xcodeproj in Xcode, open the workspace**

```bash
open /Users/dima/Projects/ispy/ispy.xcworkspace
```

- [ ] **Step 4: Build to confirm pods link correctly**

In Xcode: Product → Build (`⌘B`). Expected: Build Succeeded.

- [ ] **Step 5: Commit**

```bash
cd /Users/dima/Projects/ispy
git add Podfile Podfile.lock
git commit -m "chore: add MediaPipeTasksGenAI CocoaPods"
```

---

## Task 3: LLMService

**Files:**
- Modify: `ispy/LLMService.swift` (replace generated ContentView or create new file)

- [ ] **Step 1: Create `ispy/LLMService.swift`**

In Xcode: File → New → File → Swift File → name it `LLMService`. Make sure it's added to the `ispy` target.

Replace the entire contents with:

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
        case ready(response: String)
        case error(message: String)
    }

    static let modelFileName = "gemma-3n-E4B-it-int4.task"
    static let modelURL = URL(string:
        "https://huggingface.co/google/gemma-3n-E4B-it-litert-preview/resolve/main/gemma-3n-E4B-it-int4.task"
    )!
    static let hfToken = "REMOVED_HF_TOKEN"
    static let prompt = "Describe yourself in one sentence."

    var state: State = .needsDownload

    private var modelPath: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.modelFileName)
    }

    func start() {
        if FileManager.default.fileExists(atPath: modelPath.path) {
            loadAndRun()
        }
    }

    func download() {
        state = .downloading(progress: 0)
        var request = URLRequest(url: Self.modelURL)
        request.setValue("Bearer \(Self.hfToken)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session.downloadTask(with: request).resume()
    }

    func loadAndRun() {
        state = .loading
        let path = modelPath.path
        Task.detached(priority: .userInitiated) {
            do {
                let options = LlmInference.Options(modelPath: path)
                options.maxTokens = 1024
                let inference = try LlmInference(options: options)
                let sessionOpts = LlmInference.Session.Options()
                sessionOpts.topk = 40
                sessionOpts.temperature = 0.8
                let session = try LlmInference.Session(llmInference: inference, options: sessionOpts)
                try session.addQueryChunk(inputText: LLMService.prompt)
                let response = try session.generateResponse()
                await MainActor.run { self.state = .ready(response: response) }
            } catch {
                await MainActor.run { self.state = .error(message: error.localizedDescription) }
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
        r.setValue("Bearer \(LLMService.hfToken)", forHTTPHeaderField: "Authorization")
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
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        Task { @MainActor in self.state = .downloading(progress: p) }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let dest = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(LLMService.modelFileName)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor in self.loadAndRun() }
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

- [ ] **Step 2: Build to check for compile errors**

In Xcode: Product → Build (`⌘B`). Expected: Build Succeeded (no errors, possible warnings about unused imports are fine).

- [ ] **Step 3: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/LLMService.swift
git commit -m "feat: add LLMService — download, load, infer"
```

---

## Task 4: ContentView + entry point

**Files:**
- Modify: `ispy/ContentView.swift`
- Modify: `ispy/ispyApp.swift`

- [ ] **Step 1: Replace `ispy/ContentView.swift`**

```swift
import SwiftUI

struct ContentView: View {
    @State private var service = LLMService()

    var body: some View {
        VStack(spacing: 24) {
            switch service.state {
            case .needsDownload:
                Text("gemma-3n-E4B (~4 GB)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Download Model") {
                    service.download()
                }
                .buttonStyle(.borderedProminent)

            case .downloading(let p):
                ProgressView(value: p)
                    .padding(.horizontal)
                Text("\(Int(p * 100))%")

            case .loading:
                ProgressView()
                Text("Loading model...")

            case .ready(let response):
                Text("Prompt: \"\(LLMService.prompt)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    Text(response)
                        .padding()
                        .textSelection(.enabled)
                }

            case .error(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding()
                Button("Retry") { service.start() }
            }
        }
        .padding()
        .onAppear { service.start() }
    }
}
```

- [ ] **Step 2: Replace `ispy/ispyApp.swift`**

```swift
import SwiftUI

@main
struct ispyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

- [ ] **Step 3: Build (`⌘B`)**

Expected: Build Succeeded.

- [ ] **Step 4: Run on device**

Connect iPhone 16. In Xcode: select your device in the scheme picker → Product → Run (`⌘R`).

Expected sequence on screen:
1. "Download Model" button appears immediately
2. Tap it → progress bar counting up from 0% to 100%
3. "Loading model..." spinner
4. Model's response to "Describe yourself in one sentence."

If you see an error message instead, read it on screen and in Xcode's console (`⌘⇧C`).

- [ ] **Step 5: Commit**

```bash
cd /Users/dima/Projects/ispy
git add ispy/ContentView.swift ispy/ispyApp.swift
git commit -m "feat: SwiftUI ContentView + entry point — MVP complete"
```
