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
