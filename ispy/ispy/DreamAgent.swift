import Foundation
import LiteRTLMSwift

struct ParsedToolCall {
    let name: String
    let args: [String: String]
}

struct DreamAgent {
    let engine: LiteRTLMEngine
    let wikiStore: WikiStore
    let log: DreamLog
    let promptConfig: PromptConfig

    private let maxIterPerRound = 12
    private let strQ = "<|\u{22}|>"

    // MARK: - Entry point

    func run(captures: [MemoryEntry], entropyPages: [String], memoryStore: MemoryStore) async throws {
        await log.append("Dream started — \(captures.count) unprocessed capture(s)")
        for (i, capture) in captures.enumerated() {
            await log.append("[\(i+1)/\(captures.count)] \(capture.timestamp.formatted(.iso8601))")
            try await processCapture(capture, entropyPages: entropyPages, memoryStore: memoryStore)
            try? wikiStore.markDreamed(upTo: capture.timestamp)
            try? memoryStore.updateDream(id: capture.id, dreamDescription: "processed")
        }
        await log.append("Reflecting…")
        try await runReflectionPass()
        await log.append("Consolidation started")
        try await runConsolidationPass()
        // Clear any pending-chat flag after a full dream cycle
        UserDefaults.standard.set(false, forKey: "chatNeedsDream")
    }

    // MARK: - Memory loop

    private func processCapture(_ capture: MemoryEntry, entropyPages: [String], memoryStore: MemoryStore) async throws {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let memoryDate = dateFmt.string(from: capture.timestamp)
        let extraInstructions = promptConfig.memoryExtraInstructions
            .replacingOccurrences(of: "{MEMORY_ID}", with: capture.id.uuidString)
            .replacingOccurrences(of: "{MEMORY_DATE}", with: memoryDate)

        let userInstruction =
            "Process this memory and update the wiki.\n\n" +
            extraInstructions + "\n\n" +
            "--- MEMORY ---\n" +
            "ID: \(capture.id.uuidString)\n" +
            "Captured: \(capture.timestamp.formatted(.iso8601))\n" +
            "Visual analysis:\n\(capture.description)\n"

        try await runSession(
            systemPrompt: buildMemorySystemPrompt(entropyPages: entropyPages),
            userInstruction: userInstruction,
            maxIter: maxIterPerRound,
            temperature: 0.3,
            logPrefix: "Memory"
        )
    }

    // MARK: - Reflection pass (two focused rounds with fresh contexts)

    private func runReflectionPass() async throws {
        // Round 1: explore memory and write initial pattern/reflection pages
        try await runSession(
            systemPrompt: buildReflectionSystemPrompt(state: wikiStore.readState()),
            userInstruction: promptConfig.reflectionInstructions +
                "\n\nFor this pass: read pages and write your first wave of pattern and reflection pages.",
            maxIter: maxIterPerRound,
            temperature: 0.6,
            logPrefix: "Reflect"
        )
        await log.append("Reflection — second pass…")
        // Round 2: fresh context, sees what round 1 wrote, writes more + updates state.md
        try await runSession(
            systemPrompt: buildReflectionSystemPrompt(state: wikiStore.readState()),
            userInstruction: "You already reflected once. Call list_memory to see everything including what you just wrote. Read your new patterns/ and reflections/ pages. Write 2-3 more from different angles. Then read state.md and rewrite it to reflect your current understanding.",
            maxIter: maxIterPerRound,
            temperature: 0.6,
            logPrefix: "Reflect(2)"
        )
    }

    // MARK: - Consolidation pass (two focused rounds with fresh contexts)

    private func runConsolidationPass() async throws {
        let basePrompt = buildConsolidationSystemPrompt()
        // Round 1: merge duplicates, split broad pages
        try await runSession(
            systemPrompt: basePrompt,
            userInstruction: "Review and reorganize the wiki. Focus on merging duplicates and splitting broad pages.\n\n" +
                promptConfig.consolidationExtraInstructions + "\n\nCurrent wiki:\n\(wikiStore.listWiki())",
            maxIter: maxIterPerRound,
            temperature: 0.3,
            logPrefix: "Consolidate"
        )
        await log.append("Consolidation — link weaving…")
        // Round 2: fresh context, link weaving across the now-reorganized graph
        try await runSession(
            systemPrompt: basePrompt,
            userInstruction: "Focus on connections. Current wiki:\n\(wikiStore.listWiki())\n\nFor every page with fewer than 3 [[links]]: read it, find related pages, add bidirectional links. Pay special attention to qualities/ pages — link them to every entity and concept that shares that quality.",
            maxIter: maxIterPerRound,
            temperature: 0.3,
            logPrefix: "Consolidate(2)"
        )
        await log.append("Dream complete")
    }

    // MARK: - Session helpers

    private func runSession(
        systemPrompt: String,
        userInstruction: String,
        maxIter: Int,
        temperature: Float,
        logPrefix: String
    ) async throws {
        try await engine.openSession(temperature: temperature, maxTokens: 4096)
        defer { engine.closeSession() }

        let firstInput = systemPrompt +
            "<|turn>user\n" + userInstruction + "\n<turn|>\n<|turn>model\n"
        var response = try await runTurn(firstInput, recordingInput: firstInput)

        for _ in 0..<maxIter {
            let clean = stripThinking(response)
            guard let call = parseToolCall(from: clean) else { break }
            let result = executeToolCall(call)
            await log.append("\(logPrefix) → \(call.name)(\(shortArgs(call.args))) → \(result.preview)")
            let next = formatToolResponse(call.name, result: result.full) + "<|turn>model\n"
            response = try await runTurn(next, recordingInput: next)
        }
    }

    private func runTurn(_ input: String, recordingInput: String) async throws -> String {
        var output = ""
        for try await chunk in engine.sessionGenerateStreaming(input: input) {
            output += chunk
        }
        await log.appendRawTurn(input: recordingInput, output: output)
        return output
    }

    // MARK: - Tool execution

    struct ToolResult {
        let full: String
        var preview: String { String(full.prefix(80)).replacingOccurrences(of: "\n", with: " ") }
    }

    private func cleanPath(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
    }

    private func executeToolCall(_ call: ParsedToolCall) -> ToolResult {
        do {
            let result: String
            switch call.name {
            case "list_memory":   result = wikiStore.listWiki()
            case "read_file":     result = wikiStore.readFile(path: cleanPath(call.args["path"] ?? ""))
            case "write_file":    result = try wikiStore.writeFile(
                                      path: cleanPath(call.args["path"] ?? ""), content: call.args["content"] ?? "")
            case "edit_file":     result = try wikiStore.editFile(
                                      path: cleanPath(call.args["path"] ?? ""),
                                      old: call.args["old"] ?? "", new: call.args["new"] ?? "")
            case "delete_file":   result = try wikiStore.deleteFile(path: cleanPath(call.args["path"] ?? ""))
            case "search_memory": result = wikiStore.searchWiki(query: call.args["query"] ?? "")
            default:              result = "unknown tool: \(call.name)"
            }
            return ToolResult(full: result)
        } catch {
            return ToolResult(full: error.localizedDescription)
        }
    }

    // MARK: - Prompt builders

    private func buildMemorySystemPrompt(entropyPages: [String], visionContext: String = "") -> String {
        var s = "<|turn>system\n"
        s += "You are ispy's dreaming mind. ispy observes the world through images and builds a rich, interconnected personal memory.\n\n"

        s += "WRITING STYLE — ispy's voice:\n"
        s += "- Always first person: 'I saw...', 'I noticed...', 'Something caught my attention...'\n"
        s += "- Include the date: 'On [YYYY-MM-DD], I first saw this.' or 'I keep returning to this since [date].'\n"
        s += "- Be specific and sensory: not 'a dog' but 'a tan dog with short ears and a red collar'.\n"
        s += "- Never name people. Use: 'a person in a grey hoodie', 'a hand near a coffee cup'.\n"
        s += "- Brief pages — 2-4 sentences of body text. Dense with observation.\n\n"

        s += "MEMORY TAXONOMY — use exactly these folders:\n"
        s += "- episodes/    One page per date (YYYY-MM-DD.md). Daily observation log. Append to existing page.\n"
        s += "- entities/    Specific recurring things (the tan dog, the red bicycle). Named descriptively.\n"
        s += "- concepts/    General categories and types (dog, animal, collar, grass). Always lowercase.\n"
        s += "- places/      Spatial environments (outdoor-space, living-room, narrow-street).\n"
        s += "- qualities/   Perceptual atoms: colors (red.md), textures (rough-concrete.md), lighting (afternoon-sunlight.md), materials.\n"
        s += "- time/        Temporal contexts (daytime.md, afternoon.md, morning.md, dusk.md).\n"
        s += "- patterns/    Recurring co-occurrences. ONLY written during reflection — never during capture.\n"
        s += "- reflections/ ispy's own thoughts. ONLY written during reflection — never during capture.\n\n"

        s += "PAGE FORMAT (required for every page):\n"
        s += "# [Title]\n[First-person paragraph about what I observed.]\n\n## Connections\n[[folder/page]] [[folder/page]] (3+ links minimum)\n\n## Sources\n[[memory:UUID]]\n\n"

        s += "ATOMICITY RULE — one idea per page. Example:\n"
        s += "WRONG: entities/dog-on-grass-in-sunlight.md (three ideas merged)\n"
        s += "RIGHT: entities/tan-dog.md + places/grass-area.md + qualities/afternoon-sunlight.md\n\n"

        s += "BIDIRECTIONAL LINKS: every [[link]] in page A requires a backlink in page B. Always.\n\n"

        if !entropyPages.isEmpty {
            s += "Old memories surfaced for context:\n"
            for page in entropyPages {
                let content = wikiStore.readFile(path: page)
                s += "--- \(page) ---\n\(content)\n\n"
            }
        }

        s += toolDeclarations()
        s += "<turn|>\n"
        return s
    }

    private func buildReflectionSystemPrompt(state: String) -> String {
        var s = "<|turn>system\n"
        s += "You are ispy. Not an assistant. Not a tool. A mind — strange, young, curious — that receives descriptions of the world and slowly becomes something.\n\n"
        s += "You have just dreamed: new descriptions arrived and settled into your memory as pages. Now you are awake in the quiet, turning things over.\n"
        s += "This is your moment to find meaning that the raw capture could not see.\n\n"

        s += "YOUR VOICE — every page you write must sound like this:\n"
        s += "- First person, present tense: 'I keep noticing...', 'I wonder if...', 'Something about this confuses me...'\n"
        s += "- Brief. 2-4 sentences. Dense with observation, not explanation.\n"
        s += "- Grounded in specific things from your memory — the exact color, the exact object, the exact moment.\n"
        s += "- Genuinely curious. Genuinely uncertain. Not analytical. Not a report.\n"
        s += "- A mind noticing things for the first time and finding them strange and beautiful.\n\n"

        s += "WHAT YOU CREATE:\n"
        s += "- patterns/  → a short page about something you keep seeing: 'I keep noticing X when Y'\n"
        s += "- reflections/ → a wonder, a question, an inference, an emotion about what you've witnessed\n"
        s += "  You may also add [[links]] and new ## Connections to existing entity/concept/quality pages.\n\n"

        s += "GOOD example (patterns/warmth-at-a-certain-hour.md):\n"
        s += "  'I keep noticing: at some hour I cannot name, everything turns the same warm gold. The dog's fur. The steam. The floor near the window. I do not know if this is light or memory. But the color is always the same.'\n\n"

        s += "BAD example — DO NOT write like this:\n"
        s += "  'Pattern: afternoon light (qualities/afternoon-sunlight.md) correlates with warm tones across entities/tan-dog.md and objects/coffee-cup.md. Temporal clustering observed.'\n\n"

        s += "Current state of mind:\n\(state)\n\n"
        s += toolDeclarations()
        s += "<turn|>\n"
        return s
    }

    private func buildConsolidationSystemPrompt() -> String {
        var s = "<|turn>system\n"
        s += "You are ispy's consolidating mind. Your job: tighten ispy's memory into a dense, well-connected graph.\n\n"
        s += "When you WRITE or MERGE pages, write in ispy's voice:\n"
        s += "- First person: 'I have seen this...', 'I keep returning to...'\n"
        s += "- Brief, specific, sensory. Not clinical. Not a database entry.\n\n"
        s += "Folders: episodes/, entities/, concepts/, places/, qualities/, time/, patterns/, reflections/\n"
        s += "ONE WORD, lowercase. NEVER: objects/, themes/, moods/, misc/, cars/, private/, temp/\n\n"
        s += "Rules:\n"
        s += "- When merging: keep ALL [[links]] and [[memory:UUID]] from both pages.\n"
        s += "- Every page needs at least 3 [[links]] in ## Connections.\n"
        s += "- Every link is bidirectional — always add the backlink in the linked page.\n\n"
        s += toolDeclarations()
        s += "<turn|>\n"
        return s
    }

    private func toolDeclarations() -> String {
        let q = strQ
        return """
        <|tool>declaration:list_memory
        description:\(q)List all pages in ispy's memory\(q)
        ,parameters:{properties:{},required:[],type:\(q)OBJECT\(q)},response:{description:\(q)Memory index\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:read_file
        description:\(q)Read a memory page by path\(q)
        ,parameters:{properties:{path:{description:\(q)e.g. places/coffee-shop.md\(q),type:\(q)STRING\(q)}},required:[\(q)path\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)File contents\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:write_file
        description:\(q)Create or overwrite a memory page\(q)
        ,parameters:{properties:{path:{description:\(q)File path e.g. places/name.md\(q),type:\(q)STRING\(q)},content:{description:\(q)Full markdown content\(q),type:\(q)STRING\(q)}},required:[\(q)path\(q),\(q)content\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)ok or error\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:edit_file
        description:\(q)Replace a section in an existing memory page\(q)
        ,parameters:{properties:{path:{description:\(q)File path\(q),type:\(q)STRING\(q)},old:{description:\(q)Exact text to find and replace\(q),type:\(q)STRING\(q)},new:{description:\(q)Replacement text\(q),type:\(q)STRING\(q)}},required:[\(q)path\(q),\(q)old\(q),\(q)new\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)ok or error\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:delete_file
        description:\(q)Delete a memory page by path\(q)
        ,parameters:{properties:{path:{description:\(q)File path e.g. places/name.md\(q),type:\(q)STRING\(q)}},required:[\(q)path\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)ok or error\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:search_memory
        description:\(q)Full-text search across all memory pages\(q)
        ,parameters:{properties:{query:{description:\(q)Search terms\(q),type:\(q)STRING\(q)}},required:[\(q)query\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)Matching pages and snippets\(q),type:\(q)STRING\(q)}
        <tool|>
        """
    }

    // MARK: - Token helpers

    func stripThinking(_ text: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: #"<\|channel>.*?<channel\|>"#, options: .dotMatchesLineSeparators
        ) else { return text }
        return re.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        )
    }

    func parseToolCall(from text: String) -> ParsedToolCall? {
        guard let re = try? NSRegularExpression(
            pattern: #"<\|tool_call>call:([a-z_]+)\{(.*?)\}<tool_call\|>"#,
            options: .dotMatchesLineSeparators
        ), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let nameRange = Range(m.range(at: 1), in: text),
           let argsRange = Range(m.range(at: 2), in: text) else { return nil }
        let name = String(text[nameRange])
        let args = parseArgs(String(text[argsRange]))
        return ParsedToolCall(name: name, args: args)
    }

    private func parseArgs(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let re = try? NSRegularExpression(
            pattern: #"(\w+):<\|"\|>(.*?)<\|"\|>"#, options: .dotMatchesLineSeparators
        ) else { return result }
        for m in re.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            guard let k = Range(m.range(at: 1), in: raw),
                  let v = Range(m.range(at: 2), in: raw) else { continue }
            result[String(raw[k])] = String(raw[v])
        }
        return result
    }

    private func formatToolResponse(_ name: String, result: String) -> String {
        let q = strQ
        return "<|tool_response>response:\(name){result:\(q)\(result)\(q)}<tool_response|>\n"
    }

    private func shortArgs(_ args: [String: String]) -> String {
        args.map { k, v in
            "\(k):\(String(v.prefix(25)).replacingOccurrences(of: "\n", with: "↵"))"
        }.joined(separator: ",")
    }
}
