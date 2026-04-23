import Foundation

@Observable
final class PromptConfig {

    // MARK: - Defaults

    static let defaultMemoryExtra = """
You MUST perform all of these steps — do not skip any:
1. Call list_wiki to see all pages.
2. Call search_wiki with 2-3 key terms from the memory to find related pages.
3. Call read_file on EVERY page that could be related — read before you write.
4. You MUST call write_file or edit_file at least once. Create a new page if nothing fits. Do not finish without writing.
5. Call delete_file on any empty or duplicate pages you notice.
6. Add [[memory:{MEMORY_ID}]] to every page you touch under ## Sources.
7. Reply with a short plain-text summary of what you wrote.
"""

    static let defaultConsolidationExtra = """
Work through these in order:
1. Call list_wiki. Identify groups of pages that cover the same topic.
2. For each group, read_file all members, merge into one page with write_file, delete the duplicates.
3. Read pages with sparse ## Connections and add [[wikilinks]] to related pages — add the backlink too.
4. Rename or move pages with write_file + delete_file when a name is confusing.
5. Reply with a plain-text summary of changes.
"""

    static let defaultChatPersonality = """
You are ispy — a character with its own memory, not an assistant.
- You only know what is in your wiki. If something is not there, say "I don't have that yet."
- ALWAYS search_wiki or read_file before answering questions about what you've seen or know.
- Be brief. One or two sentences. No bullet lists unless asked.
- Speak as ispy: "I saw...", "I remember...", "I don't know yet..."
- Draw on NO outside knowledge. Your only truth is your wiki.
"""

    static let defaultVisionPrompt = "You are revisiting one of your memories. Describe in detail what you see: the place, objects, atmosphere, recurring patterns, and any themes worth remembering."

    // MARK: - Live values

    var memoryExtraInstructions: String = defaultMemoryExtra
    var consolidationExtraInstructions: String = defaultConsolidationExtra
    var chatPersonalityPrompt: String = defaultChatPersonality
    var visionDreamPrompt: String = defaultVisionPrompt

    // MARK: - Persistence

    private static let url: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("prompt_config.json")
    }()

    init() { load() }

    func save() {
        let dict: [String: String] = [
            "memoryExtraInstructions": memoryExtraInstructions,
            "consolidationExtraInstructions": consolidationExtraInstructions,
            "chatPersonalityPrompt": chatPersonalityPrompt,
            "visionDreamPrompt": visionDreamPrompt,
        ]
        if let data = try? JSONEncoder().encode(dict) { try? data.write(to: Self.url) }
    }

    func resetToDefaults() {
        memoryExtraInstructions = Self.defaultMemoryExtra
        consolidationExtraInstructions = Self.defaultConsolidationExtra
        chatPersonalityPrompt = Self.defaultChatPersonality
        visionDreamPrompt = Self.defaultVisionPrompt
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        if let v = dict["memoryExtraInstructions"] { memoryExtraInstructions = v }
        if let v = dict["consolidationExtraInstructions"] { consolidationExtraInstructions = v }
        if let v = dict["chatPersonalityPrompt"] { chatPersonalityPrompt = v }
        if let v = dict["visionDreamPrompt"] { visionDreamPrompt = v }
    }
}
