import Foundation
import LiteRTLMSwift
import UIKit

@Observable
@MainActor
final class GemmaVisionService {
    enum State: Equatable {
        case needsDownload
        case downloading
        case loading
        case ready
        case error(String)

        var isReady: Bool { self == .ready }
    }

    var state: State = .needsDownload
    var downloadProgress: Double = 0
    private let downloader = ModelDownloader()
    var engine: LiteRTLMEngine?

    func start() async {
        if downloader.isDownloaded {
            await loadModel()
        }
    }

    func download() async {
        state = .downloading
        downloadProgress = 0
        let progressTask = Task {
            while !Task.isCancelled {
                downloadProgress = downloader.progress
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        do {
            try await downloader.download()
            progressTask.cancel()
            downloadProgress = 1
            await loadModel()
        } catch {
            progressTask.cancel()
            state = .error(error.localizedDescription)
        }
    }

    private func loadModel() async {
        state = .loading
        // Try GPU first, fall back to CPU if engine creation fails
        for backend in ["gpu", "cpu"] {
            let e = LiteRTLMEngine(modelPath: downloader.modelPath, backend: backend)
            do {
                try await e.load()
                engine = e
                state = .ready
                return
            } catch {
                if backend == "cpu" {
                    state = .error(error.localizedDescription)
                }
                // else try next backend
            }
        }
    }

    func describe(image: UIImage) async throws -> String {
        guard let engine, state == .ready else { throw GemmaVisionError.notLoaded }
        let small = image.downscaled(maxDimension: 768)
        guard let imageData = small.jpegData(compressionQuality: 0.8) else {
            throw GemmaVisionError.invalidImage
        }
        return try await engine.vision(
            imageData: imageData,
            prompt: "Describe this image in detail. Include the main subject, setting, mood, and any notable details.",
            maxTokens: 400
        )
    }
}

private extension UIImage {
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

enum GemmaVisionError: LocalizedError {
    case notLoaded
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Model not ready"
        case .invalidImage: return "Could not process image"
        }
    }
}
