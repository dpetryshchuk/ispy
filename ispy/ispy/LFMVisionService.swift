import CoreImage
import Foundation
import Hub
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers
import UIKit

@Observable
@MainActor
final class LFMVisionService {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case error(String)

        var isReady: Bool { self == .ready }
        var isActive: Bool {
            switch self {
            case .idle, .ready, .error: return false
            default: return true
            }
        }

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.ready, .ready): return true
            case (.downloading(let a), .downloading(let b)): return abs(a - b) < 0.001
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var streamingOutput: String = ""

    private var container: ModelContainer?

    func load() async {
        guard container == nil, !state.isActive else { return }
        Memory.cacheLimit = 10 * 1024 * 1024
        state = .downloading(0)
        do {
            container = try await VLMModelFactory.shared.loadContainer(
                from: HubApiDownloader(),
                using: HubTokenizerLoader(),
                configuration: VLMRegistry.lfm2_5_vl_1_6B_4bit,
                progressHandler: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.state = .downloading(progress.fractionCompleted)
                    }
                }
            )
            state = .ready
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func unload() {
        container = nil
        Memory.clearCache()
        state = .idle
        streamingOutput = ""
    }

    func describe(image: UIImage) async throws -> String {
        guard let container else { throw LFMError.notLoaded }
        guard let ciImage = CIImage(image: image) else { throw LFMError.invalidImage }

        // Debug original size
        print("[LFM] Original: \(Int(ciImage.extent.width))x\(Int(ciImage.extent.height))")

        // Use UIGraphicsImageRenderer for guaranteed resize
        let maxSize: CGFloat = 256
        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resizedImage = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }

        print("[LFM] Resized to: \(Int(newSize.width))x\(Int(newSize.height))")

        guard let resizedCIImage = CIImage(image: resizedImage) else { throw LFMError.invalidImage }

        streamingOutput = ""

        let userInput = UserInput(chat: [
            .user(
                "Describe this image in detail. Include the main subject, setting, mood, and any notable details.",
                images: [.ciImage(resizedCIImage)]
            )
        ])

        let output = try await withError {
            try await container.perform { context in
                let input = try await context.processor.prepare(input: userInput)
                let stream = try MLXLMCommon.generate(
                    input: input,
                    parameters: GenerateParameters(maxTokens: 256, temperature: 0.0),
                    context: context
                )

                var result = ""
                var tokenCount = 0
                for await generation in stream {
                    if case .chunk(let text) = generation {
                        result += text
                        tokenCount += 1
                        if tokenCount % 32 == 0 {
                            Memory.clearCache()
                        }
                        let snapshot = result
                        Task { @MainActor in
                            self.streamingOutput = snapshot
                        }
                    }
                }
                return result
            }
        }

        Memory.clearCache()
        return output
    }
}

enum LFMError: LocalizedError {
    case notLoaded, invalidImage

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "FastVLM model not ready — tap Load in the Capture tab"
        case .invalidImage: return "Could not process image"
        }
    }
}

// MARK: - Downloader/TokenizerLoader (inlined from MLXHuggingFace macros, using Hub+Tokenizers)

private struct HubApiDownloader: MLXLMCommon.Downloader {
    func download(
        id: String, revision: String?, matching patterns: [String],
        useLatest: Bool, progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await HubApi.shared.snapshot(
            from: id, revision: revision ?? "main",
            matching: patterns, progressHandler: progressHandler)
    }
}

private struct HubTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
