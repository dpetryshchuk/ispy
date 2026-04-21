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
