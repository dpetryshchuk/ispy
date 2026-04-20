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
