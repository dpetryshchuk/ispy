import Foundation
import LiteRTLMSwift

struct ChatMessage: Identifiable {
    let id = UUID()
    enum Role { case user, assistant, tool(name: String) }
    let role: Role
    var text: String
    var isStreaming = false
}

struct ChatSession: Identifiable, Codable {
    let id: UUID
    let startedAt: Date
    struct Entry: Codable {
        let role: String    // "user" | "assistant"
        let text: String
    }
    let entries: [Entry]
}

@Observable
@MainActor
final class ChatService {
    private(set) var messages: [ChatMessage] = []
    private(set) var isThinking = false
    private(set) var error: String?

    private let wikiStore: WikiStore
    private let memoryStore: MemoryStore
    let promptConfig: PromptConfig
    private var engine: LiteRTLMEngine?
    private var sessionOpen = false
    private var firstTurn = true

    private let strQ = "<|\u{22}|>"
    private let maxToolIter = 15

    init(wikiStore: WikiStore, memoryStore: MemoryStore, promptConfig: PromptConfig) {
        self.wikiStore = wikiStore
        self.memoryStore = memoryStore
        self.promptConfig = promptConfig
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

        var compacted = false

        do {
            if !sessionOpen {
                try await engine.openSession(temperature: 0.7, maxTokens: 24576)
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

            var response: String
            do {
                response = try await streamTurn(turnInput)
            } catch {
                if isTokenError(error) { response = try await compactAndResend(text: text, engine: engine); compacted = true }
                else { throw error }
            }

            for _ in 0..<maxToolIter {
                let clean = stripThinking(response)
                guard let call = parseToolCall(from: clean) else { break }
                let result = executeToolCall(call)
                messages.append(ChatMessage(role: .tool(name: call.name), text: result.preview))
                let next = formatToolResponse(call.name, result: result.full) + "<|turn>model\n"
                do {
                    response = try await streamTurn(next)
                } catch {
                    if isTokenError(error) && !compacted {
                        response = try await compactAndResend(text: text, engine: engine); compacted = true
                    } else { throw error }
                }
            }
        } catch {
            self.error = error.localizedDescription
            sessionOpen = false
        }
    }

    private func isTokenError(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        return msg.contains("token") || msg.contains("context") || msg.contains("length") ||
               msg.contains("limit") || msg.contains("overflow") || msg.contains("kv")
    }

    private func compactAndResend(text: String, engine: LiteRTLMEngine) async throws -> String {
        engine.closeSession()
        sessionOpen = false

        // Build a compact conversation history from prior messages
        let history = messages.compactMap { msg -> String? in
            switch msg.role {
            case .user: return "User: \(msg.text)"
            case .assistant where !msg.text.isEmpty: return "ispy: \(msg.text)"
            default: return nil
            }
        }.dropLast().joined(separator: "\n")  // dropLast = current user turn already appended

        try await engine.openSession(temperature: 0.7, maxTokens: 24576)
        sessionOpen = true
        firstTurn = false

        let compactPrompt = buildSystemPrompt() +
            "<|turn>user\n" +
            (history.isEmpty ? "" : "Earlier in this conversation:\n\(history)\n\n") +
            "Continue from where we left off. Respond to: \(text)" +
            "<turn|>\n<|turn>model\n"

        return try await streamTurn(compactPrompt)
    }

    func reset() {
        saveSession()
        if sessionOpen { engine?.closeSession() }
        sessionOpen = false
        firstTurn = true
        messages.removeAll()
        error = nil
    }

    // MARK: - Session persistence

    private static let sessionsDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("chatsessions")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var chatNeedsDream: Bool {
        UserDefaults.standard.bool(forKey: "chatNeedsDream")
    }

    func clearChatNeedsDream() {
        UserDefaults.standard.set(false, forKey: "chatNeedsDream")
    }

    private func saveSession() {
        let entries = messages.compactMap { msg -> ChatSession.Entry? in
            switch msg.role {
            case .user: return ChatSession.Entry(role: "user", text: msg.text)
            case .assistant where !msg.text.isEmpty: return ChatSession.Entry(role: "assistant", text: msg.text)
            default: return nil
            }
        }
        guard !entries.isEmpty else { return }
        let session = ChatSession(id: UUID(), startedAt: Date(), entries: entries)
        let url = Self.sessionsDir.appendingPathComponent("\(session.id.uuidString).json")
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: url)
            UserDefaults.standard.set(true, forKey: "chatNeedsDream")
        }
    }

    func savedSessions() -> [ChatSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.sessionsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ChatSession? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ChatSession.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
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
            case "list_memory":
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
            case "search_memory":
                result = wikiStore.searchWiki(query: call.args["query"] ?? "")
            case "list_salients":
                result = listSalients()
            case "read_salient":
                result = readSalient(id: call.args["id"] ?? "")
            default:
                result = "unknown tool: \(call.name)"
            }
            return ToolResult(full: result)
        } catch {
            return ToolResult(full: error.localizedDescription)
        }
    }

    private func listSalients() -> String {
        let entries = memoryStore.entries.suffix(50)
        if entries.isEmpty { return "(no observations yet)" }
        return entries.map { e in
            "[\(e.id.uuidString)] \(e.timestamp.formatted(.iso8601)) — \(String(e.description.prefix(80)))"
        }.joined(separator: "\n")
    }

    private func readSalient(id: String) -> String {
        guard let uuid = UUID(uuidString: id),
              let entry = memoryStore.entries.first(where: { $0.id == uuid }) else {
            return "(observation not found: \(id))"
        }
        var s = "ID: \(entry.id.uuidString)\n"
        s += "Observed: \(entry.timestamp.formatted(.iso8601))\n"
        s += "Description: \(entry.description)\n"
        if let dream = entry.dreamDescription { s += "Processed notes: \(dream)\n" }
        return s
    }

    // MARK: - Prompt

    private func buildSystemPrompt() -> String {
        var s = "<|turn>system\n"
        s += promptConfig.chatPersonalityPrompt + "\n\n"
        let state = wikiStore.readState()
        s += "--- YOUR CURRENT STATE OF MIND (file: state.md) ---\n\(state)\n\n"
        s += "To update your state of mind, use write_file or edit_file on path \"state.md\".\n\n"
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
        ,parameters:{properties:{path:{description:\(q)e.g. places/coffee-shop.md\(q),type:\(q)STRING\(q)}},required:[\(q)path\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)Page contents\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:search_memory
        description:\(q)Full-text search across all memory pages\(q)
        ,parameters:{properties:{query:{description:\(q)Search terms\(q),type:\(q)STRING\(q)}},required:[\(q)query\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)Matching pages and snippets\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:write_file
        description:\(q)Create or overwrite a memory page\(q)
        ,parameters:{properties:{path:{description:\(q)File path\(q),type:\(q)STRING\(q)},content:{description:\(q)Full markdown content\(q),type:\(q)STRING\(q)}},required:[\(q)path\(q),\(q)content\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)ok or error\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:edit_file
        description:\(q)Replace a section in an existing memory page\(q)
        ,parameters:{properties:{path:{description:\(q)File path\(q),type:\(q)STRING\(q)},old:{description:\(q)Exact text to find and replace\(q),type:\(q)STRING\(q)},new:{description:\(q)Replacement text\(q),type:\(q)STRING\(q)}},required:[\(q)path\(q),\(q)old\(q),\(q)new\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)ok or error\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:delete_file
        description:\(q)Delete a memory page\(q)
        ,parameters:{properties:{path:{description:\(q)File path\(q),type:\(q)STRING\(q)}},required:[\(q)path\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)ok or error\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:list_salients
        description:\(q)List recent raw observations (up to 50)\(q)
        ,parameters:{properties:{},required:[],type:\(q)OBJECT\(q)},response:{description:\(q)Observation list with IDs and timestamps\(q),type:\(q)STRING\(q)}
        <tool|>
        <|tool>declaration:read_salient
        description:\(q)Read a specific raw observation by UUID\(q)
        ,parameters:{properties:{id:{description:\(q)Observation UUID\(q),type:\(q)STRING\(q)}},required:[\(q)id\(q)],type:\(q)OBJECT\(q)},response:{description:\(q)Observation details\(q),type:\(q)STRING\(q)}
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
