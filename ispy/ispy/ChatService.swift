import Foundation
import LiteRTLMSwift

struct ChatMessage: Identifiable {
    let id = UUID()
    enum Role { case user, assistant, tool(name: String) }
    let role: Role
    var text: String
    var isStreaming = false
}

@Observable
@MainActor
final class ChatService {
    private(set) var messages: [ChatMessage] = []
    private(set) var isThinking = false
    private(set) var error: String?

    private let wikiStore: WikiStore
    private let memoryStore: MemoryStore
    private var engine: LiteRTLMEngine?
    private var sessionOpen = false
    private var firstTurn = true

    private let strQ = "<|\u{22}|>"
    private let maxToolIter = 15

    init(wikiStore: WikiStore, memoryStore: MemoryStore) {
        self.wikiStore = wikiStore
        self.memoryStore = memoryStore
    }

    func setEngine(_ engine: LiteRTLMEngine?) {
        if self.engine !== engine {
            if sessionOpen { self.engine?.closeSession() }
            self.engine = engine
            sessionOpen = false
            firstTurn = true
        }
    }

    func send(_ text: String) async {
        guard !isThinking else { return }
        guard let engine else {
            error = "Model not loaded — open Capture tab first"
            return
        }

        messages.append(ChatMessage(role: .user, text: text))
        isThinking = true
        error = nil
        defer { isThinking = false }

        do {
            if !sessionOpen {
                try await engine.openSession(temperature: 0.7, maxTokens: 768)
                sessionOpen = true
                firstTurn = true
            }

            let turnInput: String
            if firstTurn {
                firstTurn = false
                turnInput = buildSystemPrompt() + "<|turn>user\n\(text)<turn|>\n<|turn>model\n"
            } else {
                turnInput = "<|turn>user\n\(text)<turn|>\n<|turn>model\n"
            }

            var response = try await streamTurn(turnInput)

            for _ in 0..<maxToolIter {
                let clean = stripThinking(response)
                guard let call = parseToolCall(from: clean) else { break }
                let result = executeToolCall(call)
                messages.append(ChatMessage(role: .tool(name: call.name), text: result.preview))
                let next = formatToolResponse(call.name, result: result.full) + "<|turn>model\n"
                response = try await streamTurn(next)
            }
        } catch {
            self.error = error.localizedDescription
            sessionOpen = false
        }
    }

    func reset() {
        if sessionOpen { engine?.closeSession() }
        sessionOpen = false
        firstTurn = true
        messages.removeAll()
        error = nil
    }

    // MARK: - Streaming

    private func streamTurn(_ input: String) async throws -> String {
        guard let engine else { throw ChatError.noEngine }
        var output = ""
        let idx = messages.count
        messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
        for try await chunk in engine.sessionGenerateStreaming(input: input) {
            output += chunk
            let display = stripThinking(output).replacingOccurrences(
                of: #"<\|tool_call>.*"#, with: "", options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            messages[idx].text = display
        }
        messages[idx].isStreaming = false
        return output
    }

    // MARK: - Tool execution

    struct ToolResult {
        let full: String
        var preview: String { String(full.prefix(120)).replacingOccurrences(of: "\n", with: " ") }
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
            case "delete_file":
                result = try wikiStore.deleteFile(path: cleanPath(call.args["path"] ?? ""))
            case "search_wiki":
                result = wikiStore.searchWiki(query: call.args["query"] ?? "")
            case "list_memories":
                result = listMemories()
            case "read_memory":
                result = readMemory(id: call.args["id"] ?? "")
            default:
                result = "unknown tool: \(call.name)"
            }
            return ToolResult(full: result)
        } catch {
            return ToolResult(full: error.localizedDescription)
        }
    }

    private func listMemories() -> String {
        let entries = memoryStore.entries.suffix(50)
        if entries.isEmpty { return "(no memories yet)" }
        return entries.map { e in
            "[\(e.id.uuidString)] \(e.timestamp.formatted(.iso8601)) — \(String(e.description.prefix(80)))"
        }.joined(separator: "\n")
    }

    private func readMemory(id: String) -> String {
        guard let uuid = UUID(uuidString: id),
              let entry = memoryStore.entries.first(where: { $0.id == uuid }) else {
            return "(memory not found: \(id))"
        }
        var s = "ID: \(entry.id.uuidString)\n"
        s += "Timestamp: \(entry.timestamp.formatted(.iso8601))\n"
        s += "Description: \(entry.description)\n"
        if let dream = entry.dreamDescription { s += "Dream notes: \(dream)\n" }
        return s
    }

    // MARK: - Prompt

    private func buildSystemPrompt() -> String {
        var s = "<|turn>system\n"
        s += "You are ispy — a personal AI that observes and remembers the world for your user.\n"
        s += "You have a wiki of memories and can search, read, and update it during this chat.\n"
        s += "Be conversational, warm, and specific. Reference actual pages and memories when relevant.\n"
        s += "When asked about something you've seen or recorded, use your tools to look it up first.\n\n"
        s += toolDeclarations()
        s += "<turn|>\n"
        return s
    }

    private func toolDeclarations() -> String {
        let q = strQ
        return """
        <|tool>declaration:list_wiki
        description:\(q)List all pages in the wiki index\(q)
        ,parameters:{properties:{},required:[],type:\(q)OBJECT\(q)},response:{description:\(q)Wiki index\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:read_file
        description:\(q)Read a wiki page by path (relative to wiki/)\(q)
        ,parameters:{properties:{path:{description:\(q)e.g. places/coffee-shop.md\(q),type:\(q)STRING\(q)}},required:[\(q)path\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)File contents\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:search_wiki
        description:\(q)Full-text search across all wiki pages\(q)
        ,parameters:{properties:{query:{description:\(q)Search terms\(q),type:\(q)STRING\(q)}},required:[\(q)query\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)Matching filenames and snippets\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:write_file
        description:\(q)Create or overwrite a wiki page\(q)
        ,parameters:{properties:{path:{description:\(q)File path\(q),type:\(q)STRING\(q)},content:{description:\(q)Full markdown content\(q),type:\(q)STRING\(q)}},required:[\(q)path\(q),\(q)content\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)ok or error\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:edit_file
        description:\(q)Replace a section in an existing wiki page\(q)
        ,parameters:{properties:{path:{description:\(q)File path\(q),type:\(q)STRING\(q)},old:{description:\(q)Exact text to find and replace\(q),type:\(q)STRING\(q)},new:{description:\(q)Replacement text\(q),type:\(q)STRING\(q)}},required:[\(q)path\(q),\(q)old\(q),\(q)new\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)ok or error\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:delete_file
        description:\(q)Delete a wiki page\(q)
        ,parameters:{properties:{path:{description:\(q)File path\(q),type:\(q)STRING\(q)}},required:[\(q)path\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)ok or error\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:list_memories
        description:\(q)List recent memory captures (up to 50)\(q)
        ,parameters:{properties:{},required:[],type:\(q)OBJECT\(q)},response:{description:\(q)List of memory entries with IDs and timestamps\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:read_memory
        description:\(q)Read a specific memory entry by UUID\(q)
        ,parameters:{properties:{id:{description:\(q)Memory UUID\(q),type:\(q)STRING\(q)}},required:[\(q)id\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)Memory details\(q),type:\(q)STRING\(q)}
        <tool|>
        """
    }

    // MARK: - Token helpers (reused from DreamAgent)

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
}

enum ChatError: LocalizedError {
    case noEngine
    var errorDescription: String? { "Model not loaded" }
}
