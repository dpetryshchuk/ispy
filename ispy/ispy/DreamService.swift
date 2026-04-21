import Foundation
import MediaPipeTasksGenAI

final class DreamService {
    private let inference: LlmInference

    init(inference: LlmInference) {
        self.inference = inference
    }

    func describe(visionData: String) throws -> String {
        let sessionOpts = LlmInference.Session.Options()
        sessionOpts.topk = 40
        sessionOpts.temperature = 0.9
        let session = try LlmInference.Session(llmInference: inference, options: sessionOpts)
        let prompt = """
        You are ispy, a personal AI that helps build memories from photos.

        On-device vision analysis detected the following in a photo:
        \(visionData)

        Write a vivid, specific 2-4 sentence description of what this image likely shows. Be concrete about the main subject, setting, and atmosphere. Focus on what makes this moment memorable.
        """
        try session.addQueryChunk(inputText: prompt)
        return try session.generateResponse()
    }
}
