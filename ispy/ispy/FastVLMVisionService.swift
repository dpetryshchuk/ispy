import CoreImage
import Foundation
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import UIKit

@Observable
@MainActor
final class FastVLMVisionService {
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
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        state = .downloading(0)
        do {
            container = try await VLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: VLMRegistry.fastvlm,
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
        MLX.GPU.clearCache()
        state = .idle
        streamingOutput = ""
    }

    func describe(image: UIImage) async throws -> String {
        guard let container else { throw FastVLMError.notLoaded }
        guard let ciImage = CIImage(image: image) else { throw FastVLMError.invalidImage }

        streamingOutput = ""

        let userInput = UserInput(
            prompt: .text(
                "Describe this image in detail. Include the main subject, setting, mood, and any notable details."
            ),
            images: [.ciImage(ciImage)]
        )

        let result = try await container.perform { context in
            let input = try await context.processor.prepare(input: userInput)
            var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)

            return try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(temperature: 0.0),
                context: context
            ) { [self] tokens in
                if let last = tokens.last {
                    detokenizer.append(token: last)
                }
                if let newText = detokenizer.next() {
                    Task { @MainActor in
                        self.streamingOutput += newText
                    }
                }
                return tokens.count >= 800 ? .stop : .more
            }
        }

        return result.output
    }
}

enum FastVLMError: LocalizedError {
    case notLoaded, invalidImage

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "FastVLM model not ready — tap Load in the Capture tab"
        case .invalidImage: return "Could not process image"
        }
    }
}
