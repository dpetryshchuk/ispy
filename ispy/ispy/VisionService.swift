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
