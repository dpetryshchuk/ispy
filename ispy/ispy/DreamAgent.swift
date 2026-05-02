import Foundation
import LiteRTLMSwift

struct DreamAgent {
    let engine: LiteRTLMEngine
    let wikiStore: WikiStore
    let log: DreamLog
    let promptConfig: PromptConfig
    var shouldCancel: () -> Bool = { false }

    private static let maxIterMemory = 32
    private static let maxIterReflection = 16
    private static let maxIterConsolidation = 50

    // MARK: - Entry point

    func run(captures: [MemoryEntry], entropyPages: [String], memoryStore: MemoryStore) async throws {
        await log.beginPhase("Captures (\(captures.count))")
        var cancelled = false
        for (i, capture) in captures.enumerated() {
            if shouldCancel() {
                await log.logInfo("⚠ Stopped by user")
                cancelled = true
                break
            }
            let snippet = capture.description
                .components(separatedBy: .newlines)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                .map { String($0.prefix(60)) } ?? capture.timestamp.formatted(.dateTime.month().day().hour().minute())
            await log.beginStep("[\(i+1)/\(captures.count)] \(snippet)")
            try await processCapture(capture, entropyPages: entropyPages, memoryStore: memoryStore)
            try? wikiStore.markDreamed(upTo: capture.timestamp)
            try? memoryStore.updateDream(id: capture.id, dreamDescription: "processed")
            await log.endStep(success: true)
        }
        await log.endPhase(success: !cancelled)
        guard !cancelled && !shouldCancel() else { return }
        try await runReflectionPass()
        guard !shouldCancel() else { return }
        try await runConsolidationPass()
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
            maxIter: Self.maxIterMemory,
            temperature: 0.3,
            logPrefix: "Memory"
        )
    }

    // MARK: - Reflection pass (two focused rounds with fresh contexts)

    func runReflectionPass() async throws {
        await log.beginPhase("Reflection")
        await log.beginStep("Pass 1 — initial patterns")
        try await runSession(
            systemPrompt: buildReflectionSystemPrompt(state: wikiStore.readState()),
            userInstruction: promptConfig.reflectionInstructions +
                "\n\nFor this pass: read pages and write your first wave of pattern and reflection pages.",
            maxIter: Self.maxIterReflection,
            temperature: 0.6,
            logPrefix: "Reflect"
        )
        await log.endStep(success: true)
        await log.beginStep("Pass 2 — deepen + update state")
        try await runSession(
            systemPrompt: buildReflectionSystemPrompt(state: wikiStore.readState()),
            userInstruction: "You already reflected once. Call list_memory to see everything including what you just wrote. Read your new patterns/ and reflections/ pages. Write 2-3 more from different angles. Then read state.md and rewrite it to reflect your current understanding.",
            maxIter: Self.maxIterReflection,
            temperature: 0.6,
            logPrefix: "Reflect(2)"
        )
        await log.endStep(success: true)
        await log.endPhase(success: true)
    }

    // MARK: - Consolidation pass (two focused rounds with fresh contexts)

    func runConsolidationPass() async throws {
        let basePrompt = buildConsolidationSystemPrompt()
        let hotPages = wikiStore.topAccessedPages(limit: 10)
        let hotList = hotPages.isEmpty ? "" : "\n\nMost-visited pages (prioritize keeping these rich and well-linked):\n" + hotPages.map { "- \($0)" }.joined(separator: "\n")
        let wiki = wikiStore.listWiki()

        await log.beginPhase("Consolidation")

        await log.beginStep("Scan and merge duplicates")
        try await runSession(
            systemPrompt: basePrompt,
            userInstruction: """
            PHASE 1 — FULL SCAN AND MERGE.

            Current wiki (all pages):
            \(wiki)\(hotList)

            \(promptConfig.consolidationExtraInstructions)

            Your job this round:
            1. Read EVERY file listed above. All of them. Use read_file on each one.
            2. As you read, note duplicates: pages in the same folder about the same thing (e.g. kitchen.md + kitchen-counter.md + kitchen-space.md).
            3. For each duplicate set: write_file a single merged page (all content, all links, all sources), then delete_file each redundant page.
            4. For each deleted page: search_memory for its name, then edit_file every page that linked to it to point to the merged page instead.
            Do not stop until you have read every file.
            """,
            maxIter: Self.maxIterConsolidation,
            temperature: 0.2,
            logPrefix: "Consolidate"
        )

        await log.endStep(success: true)

        await log.beginStep("Abstract grouping and synthesis")
        try await runSession(
            systemPrompt: basePrompt,
            userInstruction: """
            PHASE 2 — ABSTRACT GROUPING AND SYNTHESIS.

            Current wiki (after merging):
            \(wikiStore.listWiki())\(hotList)

            Your job this round:
            1. List all files again. For each folder, look for 3+ pages that share a property with no concept page for it.
               Create the abstraction: concepts/animals.md if dog+cat+bird exist, concepts/warmth.md if multiple warm-toned pages exist, etc.
            2. Read every page you haven't read yet. Look for ideas that deserve their own new page — a recurring color, a recurring time of day, a recurring place.
            3. Write new pages for every abstraction and synthesis you find. Link them to every relevant page bidirectionally.
            4. If a page covers 2+ unrelated concepts, split it: write both halves, delete the original.
            Do not stop until you have processed every page.
            """,
            maxIter: Self.maxIterConsolidation,
            temperature: 0.3,
            logPrefix: "Consolidate(2)"
        )

        await log.endStep(success: true)

        await log.beginStep("Link weaving")
        try await runSession(
            systemPrompt: basePrompt,
            userInstruction: """
            PHASE 3 — LINK WEAVING.

            Current wiki (after grouping):
            \(wikiStore.listWiki())\(hotList)

            Your job this round:
            1. Read every page. For each one: find 2-3 pages it should link to but doesn't. Add the link inline and add the backlink.
            2. Every qualities/ page must link to every entity and concept sharing that quality.
            3. Every concepts/ page must link to every entity that is an instance of it.
            4. Every page needs at least 3 [[links]]. Find every page with fewer and fix it.
            5. Find orphaned pages (nothing links to them). Connect them into the graph.
            Do not stop until every page has been read and linked.
            """,
            maxIter: Self.maxIterConsolidation,
            temperature: 0.3,
            logPrefix: "Consolidate(3)"
        )
        await log.endStep(success: true)
        await log.endPhase(success: true)
    }

    // MARK: - Session helpers

    private func runSession(
        systemPrompt: String,
        userInstruction: String,
        maxIter: Int,
        temperature: Float,
        logPrefix: String
    ) async throws {
        let pagesAtStart = wikiStore.pageCount()
        var remainingIter = maxIter
        var currentInstruction = userInstruction

        while remainingIter > 0 {
            guard !shouldCancel() else { return }
            do {
                try await engine.openSession(temperature: temperature, maxTokens: 16384)
                defer { engine.closeSession() }

                let firstInput = systemPrompt +
                    "<|turn>user\n" + currentInstruction + "\n<turn|>\n<|turn>model\n"
                var response = try await runTurn(firstInput, recordingInput: firstInput)
                await log.logLLM(String(ToolCallParser.stripThinking(response).prefix(160)))

                while remainingIter > 0 {
                    guard !shouldCancel() else { return }
                    let clean = ToolCallParser.stripThinking(response)
                    guard let call = ToolCallParser.parse(from: clean) else { break }
                    let result = executeToolCall(call)
                    let argPreview = (call.args["path"] ?? call.args.first.map { "\($0.key):\($0.value)" } ?? "")
                        .prefix(60).replacingOccurrences(of: "\n", with: "↵")
                    await log.logTool(call.name, args: String(argPreview), preview: result.preview)
                    let next = ToolCallParser.formatResponse(call.name, result: result.full) + "<|turn>model\n"
                    response = try await runTurn(next, recordingInput: next)
                    await log.logLLM(String(ToolCallParser.stripThinking(response).prefix(160)))
                    remainingIter -= 1
                }
                return // completed normally

            } catch {
                let msg = error.localizedDescription.lowercased()
                let isTokenError = msg.contains("token") || msg.contains("context") ||
                                   msg.contains("length") || msg.contains("limit") ||
                                   msg.contains("overflow") || msg.contains("kv")
                guard isTokenError && remainingIter > 0 else { throw error }
                let pagesCreated = wikiStore.pageCount() - pagesAtStart
                await log.logInfo("⚠ token limit — compacting (\(remainingIter) iters left, \(pagesCreated) pages created)")
                // Do NOT include the original task — that causes the model to re-plan from scratch.
                // Just show current state and tell it to continue the next uncompleted action.
                currentInstruction = """
                    Context compacted — \(pagesCreated) page\(pagesCreated == 1 ? "" : "s") saved so far this session. DO NOT re-plan. Call the NEXT tool immediately to continue where you stopped.

                    Current wiki (\(wikiStore.pageCount()) pages total):
                    \(wikiStore.listWiki())
                    """
            }
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
        s += "# [Title]\n[First-person paragraph. Link concepts INLINE as they first appear: 'a [[qualities/tan]] dog with a [[qualities/red]] collar ran across the [[places/grass-area]]'.]\n\n## Connections\n[[folder/page]] [[folder/page]] (3+ additional links minimum)\n\n## Sources\n[[exp:UUID]]\n\n"

        s += "INLINE LINKS RULE — the most important rule:\n"
        s += "Link the FIRST mention of every notable quality, concept, entity, or place directly in the sentence where it appears.\n"
        s += "WRONG: 'A tan dog ran across the grass.' ... ## Connections [[qualities/tan]] [[places/grass-area]]\n"
        s += "RIGHT:  'A [[qualities/tan]] dog ran across the [[places/grass-area]].'\n"
        s += "The ## Connections section is for links that didn't fit inline (abstract relationships, less prominent mentions).\n\n"

        s += "FILE SYSTEM: Files are stored flat. 'folder/page.md' just means the file is named that — no separate folder creation needed. Use write_file with any path like 'qualities/tan.md' and it works immediately.\n\n"
        s += "ATOMICITY RULE — one idea per page. Example:\n"
        s += "WRONG: entities/dog-on-grass-in-sunlight.md (three ideas merged)\n"
        s += "RIGHT: entities/tan-dog.md + places/grass-area.md + qualities/afternoon-sunlight.md\n\n"

        s += "BIDIRECTIONAL LINKS: every [[link]] in page A requires a backlink in page B. Always.\n\n"

        s += "TOOL RULE: After your initial plan, act immediately — call tools, do not describe what you plan to do. One tool call per turn.\n\n"

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
        s += "LINKING: weave [[links]] inline at first mention — 'the [[qualities/tan]] fur', 'that particular [[time/afternoon]]'. ## Connections is for secondary relationships only.\n\n"

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
        s += "- When merging: keep ALL [[links]] and [[exp:UUID]] from both pages.\n"
        s += "- Inline links: every notable quality, concept, entity, or place gets [[linked]] at its first mention in the body text, not just collected at the bottom.\n"
        s += "- ## Connections is for additional abstract relationships that didn't fit inline.\n"
        s += "- Every link is bidirectional — always add the backlink in the linked page.\n\n"
        s += toolDeclarations()
        s += "<turn|>\n"
        return s
    }

    private func toolDeclarations() -> String {
        let q = ToolCallParser.strQ
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

}
