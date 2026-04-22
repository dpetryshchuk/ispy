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

    private let maxMemoryIter = 20
    private let maxConsolidationIter = 30

    private let strQ = "<|\u{22}|>"

    // MARK: - Entry point

    func run(captures: [MemoryEntry], entropyPages: [String], memoryStore: MemoryStore) async throws {
        await log.append("Dream started — \(captures.count) unprocessed capture(s)")
        for (i, capture) in captures.enumerated() {
            await log.append("[\(i+1)/\(captures.count)] \(capture.timestamp.formatted(.iso8601))")
            try await processCapture(capture, entropyPages: entropyPages, memoryStore: memoryStore)
        }
        await log.append("Consolidation started")
        try await runConsolidationPass()
    }

    // MARK: - Memory loop

    private func processCapture(_ capture: MemoryEntry, entropyPages: [String], memoryStore: MemoryStore) async throws {
        // Look at the actual photo during dreaming — fresh vision pass before the tool loop
        var visionContext = ""
        let photoURL = memoryStore.photoURL(for: capture)
        if let imageData = try? Data(contentsOf: photoURL) {
            await log.append("→ vision()")
            let dreamPrompt = "You are revisiting one of your memories. Describe in detail what you see: the place, objects, atmosphere, recurring patterns, and any themes worth remembering."
            if let fresh = try? await engine.vision(imageData: imageData, prompt: dreamPrompt, maxTokens: 256) {
                visionContext = fresh
            }
        }

        try await engine.openSession(temperature: 0.3, maxTokens: 512)

        defer { engine.closeSession() }

        let systemBlock = buildMemorySystemPrompt(entropyPages: entropyPages, visionContext: visionContext)
        let firstInput = systemBlock +
            "<|turn>user\n" +
            "Process this memory and update the wiki. Use list_wiki to see existing pages, " +
            "read_file to inspect relevant ones, then write_file or edit_file to update. " +
            "Write wiki pages in first person. Add a ## Sources section containing [[memory:\(capture.id.uuidString)]] " +
            "to every page you create or update for this memory. " +
            "When finished, respond with plain text only (no tool call).\n\n" +
            "Memory ID: \(capture.id.uuidString)\n" +
            "Memory timestamp (UTC): \(capture.timestamp.formatted(.iso8601))\n" +
            "Memory description:\n\(capture.description)\n" +
            "<turn|>\n<|turn>model\n"

        var response = try await runTurn(firstInput)

        for _ in 0..<maxMemoryIter {
            let clean = stripThinking(response)
            guard let call = parseToolCall(from: clean) else { break }
            let result = executeToolCall(call)
            await log.append("→ \(call.name)(\(shortArgs(call.args))) → \(result.preview)")
            let responseInput = formatToolResponse(call.name, result: result.full) + "<|turn>model\n"
            response = try await runTurn(responseInput)
        }
    }

    // MARK: - Consolidation pass

    private func runConsolidationPass() async throws {
        try await engine.openSession(temperature: 0.3, maxTokens: 512)

        defer { engine.closeSession() }

        let index = wikiStore.listWiki()
        let firstInput = buildConsolidationSystemPrompt() +
            "<|turn>user\n" +
            "Review the wiki index and clean it up: merge duplicate pages, " +
            "add missing [[wikilinks]] between related pages. " +
            "When finished, respond with plain text only (no tool call).\n\n" +
            "Wiki index:\n\(index)\n" +
            "<turn|>\n<|turn>model\n"

        var response = try await runTurn(firstInput)

        for _ in 0..<maxConsolidationIter {
            let clean = stripThinking(response)
            guard let call = parseToolCall(from: clean) else { break }
            let result = executeToolCall(call)
            await log.append("Consolidate → \(call.name)(\(shortArgs(call.args))) → \(result.preview)")
            let responseInput = formatToolResponse(call.name, result: result.full) + "<|turn>model\n"
            response = try await runTurn(responseInput)
        }

        await log.append("Dream complete")
    }

    // MARK: - Session turn

    private func runTurn(_ input: String) async throws -> String {
        var output = ""
        for try await chunk in engine.sessionGenerateStreaming(input: input) {
            output += chunk
        }
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
            case "list_wiki":
                result = wikiStore.listWiki()
            case "read_file":
                result = wikiStore.readFile(path: cleanPath(call.args["path"] ?? ""))
            case "write_file":
                result = try wikiStore.writeFile(
                    path: cleanPath(call.args["path"] ?? ""), content: call.args["content"] ?? ""
                )
            case "edit_file":
                result = try wikiStore.editFile(
                    path: cleanPath(call.args["path"] ?? ""),
                    old: call.args["old"] ?? "",
                    new: call.args["new"] ?? ""
                )
            case "search_wiki":
                result = wikiStore.searchWiki(query: call.args["query"] ?? "")
            default:
                result = "unknown tool: \(call.name)"
            }
            return ToolResult(full: result)
        } catch {
            return ToolResult(full: error.localizedDescription)
        }
    }

    // MARK: - Prompt builders

    private func buildMemorySystemPrompt(entropyPages: [String], visionContext: String = "") -> String {
        var s = "<|turn>system\n"
        s += "You are ispy's dreaming mind. ispy observes the world through images and maintains a personal wiki.\n\n"
        s += "Wiki writing style:\n"
        s += "- Write in FIRST PERSON: 'I saw...', 'I visited...', 'I noticed...', 'I encountered...'\n"
        s += "- Include when you observed it: 'On [YYYY-MM-DD], I saw...' or 'I first noticed this on [date].'\n\n"
        s += "Wiki rules:\n"
        s += "- Pages cover observable things only: places, recurring objects, themes, moods.\n"
        s += "- Never name people — use descriptive labels like 'person in red jacket'.\n"
        s += "- Each page: H1 title, first-person description paragraph, ## Connections section with [[wikilinks]], ## Sources section with [[memory:UUID]] links.\n"
        s += "- Folder names should be ONE WORD, lowercase, and simple: places/, objects/, themes/, moods/, people/, cars/.\n"
        s += "- NEVER use words like 'private', 'temp', 'misc', 'other' in folder names.\n"
        s += "- When you link two pages together, add the [[wikilink]] to BOTH pages' ## Connections sections.\n\n"

        if !visionContext.isEmpty {
            s += "What I see when I look at this memory's photo:\n\(visionContext)\n\n"
        }

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

    private func buildConsolidationSystemPrompt() -> String {
        var s = "<|turn>system\n"
        s += "You are ispy's consolidating mind. Your job: merge duplicate wiki pages and add missing [[wikilinks]].\n"
        s += "Rules:\n"
        s += "- Connect related pages by adding [[wikilinks]] to BOTH pages' ## Connections sections.\n"
        s += "- Only consolidate existing pages, don't create new ones.\n"
        s += "- Folder names must be ONE WORD, lowercase, and simple. NEVER use 'private', 'temp', 'misc', 'other'.\n\n"
        s += toolDeclarations()
        s += "<turn|>\n"
        return s
    }

    private func toolDeclarations() -> String {
        let q = strQ
        return """
        <|tool>declaration:list_wiki
        description:\(q)List all pages in the wiki index\(q)
        ,parameters:{properties:{},required:[],type:\(q)OBJECT\(q)},response:{description:\(q)Wiki index markdown\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:read_file
        description:\(q)Read a wiki page by path (relative to wiki/)\(q)
        ,parameters:{properties:{path:{description:\(q)e.g. places/coffee-shop.md\(q),type:\(q)STRING\(q)}},required:[\(q)path\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)File contents\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:write_file
        description:\(q)Create or overwrite a wiki page\(q)
        ,parameters:{properties:{path:{description:\(q)File path e.g. places/name.md\(q),type:\(q)STRING\(q)},content:{description:\(q)Full markdown content\(q),type:\(q)STRING\(q)}},required:[\(q)path\(q),\(q)content\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)ok or error\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:edit_file
        description:\(q)Replace a section in an existing wiki page\(q)
        ,parameters:{properties:{path:{description:\(q)File path\(q),type:\(q)STRING\(q)},old:{description:\(q)Exact text to find and replace\(q),type:\(q)STRING\(q)},new:{description:\(q)Replacement text\(q),type:\(q)STRING\(q)}},required:[\(q)path\(q),\(q)old\(q),\(q)new\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)ok or error\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:search_wiki
        description:\(q)Full-text search across all wiki pages\(q)
        ,parameters:{properties:{query:{description:\(q)Search terms\(q),type:\(q)STRING\(q)}},required:[\(q)query\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)Matching filenames and first-line snippets\(q),type:\(q)STRING\(q)}
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