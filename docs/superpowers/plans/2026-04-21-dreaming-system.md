# Dreaming System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build ispy's dreaming system — a manual/scheduled Gemma 4 agent loop that processes unprocessed captures and builds an Obsidian-style wiki using tool calling.

**Architecture:** MemoryStore is refactored to store captures in `raw/YYYY-MM-DD/` dated folders. WikiStore manages the `wiki/` filesystem and implements 5 agent tools (read/write/edit/search/list). DreamAgent runs Gemma 4 E2B's iterative tool-calling loop using `sessionGenerateStreaming()` for KV cache reuse, with a memory loop then a GC pass. DreamService orchestrates the pipeline and exposes `isRunning` state. DreamView streams the live log.

**Tech Stack:** Swift/SwiftUI, LiteRTLMSwift (`openSession`, `sessionGenerateStreaming`, `closeSession`), Gemma 4 E2B special tokens (`<|turn>`, `<|tool>`, `<|tool_call>`, `<|tool_response>`, `<|"|>`), BGProcessingTask for nightly scheduling.

**Gemma 4 Tool Call Format (critical):**
- Model emits: `<|tool_call>call:name{key:<|"|>value<|"|>}<tool_call|>` then stops
- We inject: `<|tool_response>response:name{result:<|"|>value<|"|>}<tool_response|>`
- String values use `<|"|>` as delimiter (NOT JSON quotes)
- `<tool_call|>` acts as EOG — `sessionGenerateStreaming` stream ends at it

---

## File Map

**Modified:**
- `ispy/ispy/MemoryStore.swift` — refactor to `raw/YYYY-MM-DD/` storage + one-time migration from legacy flat format
- `ispy/ispy/GemmaVisionService.swift` — change `private var engine` to `var engine` (internal access)
- `ispy/ispy/RootView.swift` — add DreamService + WikiStore state, add DreamView tab

**Created:**
- `ispy/ispy/WikiStore.swift` — wiki filesystem + 5 tools + `dream.json` cursor + `cache.json`
- `ispy/ispy/DreamLog.swift` — `@Observable` log model with timestamped entries
- `ispy/ispy/DreamAgent.swift` — Gemma 4 tool-calling loop (struct, pure logic)
- `ispy/ispy/DreamService.swift` — `@MainActor` orchestrator: entropy selection, model check, agent dispatch
- `ispy/ispy/DreamView.swift` — dream log UI + Dream button + model status banner

---

### Task 1: Refactor MemoryStore to raw/YYYY-MM-DD/ dated structure

**Files:**
- Modify: `ispy/ispy/MemoryStore.swift`

Current `MemoryStore` writes to `Documents/memory/index.json` and `Documents/memory/photos/<uuid>.jpg`. This task moves to `Documents/memory/raw/YYYY-MM-DD/captures.json` and `Documents/memory/raw/YYYY-MM-DD/photos/<uuid>.jpg`. A one-time migration runs at init if the legacy files exist. The public API (`entries`, `save`, `updateDream`, `photoURL`) keeps the same signatures so `MemoryView` needs no changes.

- [ ] **Step 1: Replace MemoryStore.swift with the new implementation**

```swift
// ispy/ispy/MemoryStore.swift
import Foundation
import UIKit

struct MemoryEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    var description: String
    let photoFilename: String
    var dreamDescription: String?
}

enum MemoryError: Error {
    case invalidImage
    case entryNotFound
}

@Observable
final class MemoryStore {
    private(set) var entries: [MemoryEntry] = []

    let memoryDir: URL
    let rawDir: URL

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        memoryDir = docs.appendingPathComponent("memory")
        rawDir = memoryDir.appendingPathComponent("raw")
        try? FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        migrateFromLegacyIfNeeded()
        entries = allEntries()
    }

    func save(image: UIImage, description: String) throws {
        let id = UUID()
        let filename = "\(id.uuidString).jpg"
        let timestamp = Date()
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            throw MemoryError.invalidImage
        }
        let photosDir = dayPhotosDir(for: timestamp)
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        try data.write(to: photosDir.appendingPathComponent(filename))
        let entry = MemoryEntry(
            id: id, timestamp: timestamp, description: description, photoFilename: filename
        )
        let dir = dayDirectory(for: timestamp)
        var dayEntries = loadDayEntries(dayDir: dir)
        dayEntries.append(entry)
        try writeDayEntries(dayEntries, dayDir: dir)
        entries = allEntries()
    }

    func updateDream(id: UUID, dreamDescription: String) throws {
        guard let entry = entries.first(where: { $0.id == id }) else {
            throw MemoryError.entryNotFound
        }
        let dir = dayDirectory(for: entry.timestamp)
        var dayEntries = loadDayEntries(dayDir: dir)
        guard let idx = dayEntries.firstIndex(where: { $0.id == id }) else {
            throw MemoryError.entryNotFound
        }
        dayEntries[idx].dreamDescription = dreamDescription
        try writeDayEntries(dayEntries, dayDir: dir)
        entries = allEntries()
    }

    func photoURL(for entry: MemoryEntry) -> URL {
        dayPhotosDir(for: entry.timestamp).appendingPathComponent(entry.photoFilename)
    }

    // MARK: - Helpers used by WikiStore / DreamAgent

    func dayDirectory(for date: Date) -> URL {
        rawDir.appendingPathComponent(Self.dayFormatter.string(from: date))
    }

    func capturesURL(dayDir: URL) -> URL {
        dayDir.appendingPathComponent("captures.json")
    }

    func allDayDirectories() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: rawDir, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? [])
        .filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func loadDayEntries(dayDir: URL) -> [MemoryEntry] {
        let url = capturesURL(dayDir: dayDir)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([MemoryEntry].self, from: data)) ?? []
    }

    // MARK: - Private

    private func dayPhotosDir(for date: Date) -> URL {
        dayDirectory(for: date).appendingPathComponent("photos")
    }

    private func allEntries() -> [MemoryEntry] {
        allDayDirectories().flatMap { loadDayEntries(dayDir: $0) }
    }

    private func writeDayEntries(_ entries: [MemoryEntry], dayDir: URL) throws {
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: capturesURL(dayDir: dayDir))
    }

    private func migrateFromLegacyIfNeeded() {
        let legacyIndex = memoryDir.appendingPathComponent("index.json")
        let legacyPhotos = memoryDir.appendingPathComponent("photos")
        guard FileManager.default.fileExists(atPath: legacyIndex.path),
              let data = try? Data(contentsOf: legacyIndex),
              let oldEntries = try? JSONDecoder().decode([MemoryEntry].self, from: data) else { return }
        for entry in oldEntries {
            let dir = dayDirectory(for: entry.timestamp)
            let photosDir = dayPhotosDir(for: entry.timestamp)
            try? FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
            let oldPhoto = legacyPhotos.appendingPathComponent(entry.photoFilename)
            let newPhoto = photosDir.appendingPathComponent(entry.photoFilename)
            if FileManager.default.fileExists(atPath: oldPhoto.path) {
                try? FileManager.default.copyItem(at: oldPhoto, to: newPhoto)
            }
            var dayEntries = loadDayEntries(dayDir: dir)
            if !dayEntries.contains(where: { $0.id == entry.id }) {
                dayEntries.append(entry)
                try? writeDayEntries(dayEntries, dayDir: dir)
            }
        }
        try? FileManager.default.removeItem(at: legacyIndex)
        try? FileManager.default.removeItem(at: legacyPhotos)
    }
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

Expected: Build succeeds. `MemoryView` still compiles — `entries` and `photoURL(for:)` have the same signatures.

- [ ] **Step 3: Run on device, verify existing memories appear in Memory tab**

Expected: Previously saved memories show with correct photos. New saves go to `raw/YYYY-MM-DD/`.

- [ ] **Step 4: Commit**

```bash
git add ispy/ispy/MemoryStore.swift
git commit -m "refactor: MemoryStore writes to raw/YYYY-MM-DD/ dated structure with legacy migration"
```

---

### Task 2: WikiStore — filesystem layer with 5 agent tools

**Files:**
- Create: `ispy/ispy/WikiStore.swift`

WikiStore owns `Documents/memory/wiki/` and implements the 5 tools the dream agent calls. It also manages `dream.json` (the `lastDreamed` UTC timestamp cursor) and `cache.json` (list of wiki pages with last-accessed timestamps, used for entropy injection).

- [ ] **Step 1: Create WikiStore.swift**

```swift
// ispy/ispy/WikiStore.swift
import Foundation

struct CacheEntry: Codable {
    let page: String
    var lastSeen: Date
}

final class WikiStore {
    let wikiDir: URL
    private let dreamStateURL: URL
    private let cacheURL: URL
    private let iso = ISO8601DateFormatter()

    init(memoryDir: URL) {
        wikiDir = memoryDir.appendingPathComponent("wiki")
        dreamStateURL = memoryDir.appendingPathComponent("dream.json")
        cacheURL = memoryDir.appendingPathComponent("cache.json")
        for sub in ["places", "themes", "objects"] {
            try? FileManager.default.createDirectory(
                at: wikiDir.appendingPathComponent(sub), withIntermediateDirectories: true
            )
        }
        ensureWikiIndex()
    }

    // MARK: - Dream cursor

    var lastDreamed: Date? {
        guard let data = try? Data(contentsOf: dreamStateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let str = obj["lastDreamed"] else { return nil }
        return iso.date(from: str)
    }

    func markDreamed() throws {
        let obj: [String: String] = ["lastDreamed": iso.string(from: Date())]
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: dreamStateURL)
    }

    // MARK: - Cache

    func cacheEntries() -> [CacheEntry] {
        guard let data = try? Data(contentsOf: cacheURL),
              let list = try? JSONDecoder().decode([CacheEntry].self, from: data) else { return [] }
        return list
    }

    func oldestCachePages(limit: Int) -> [String] {
        Array(cacheEntries().sorted { $0.lastSeen < $1.lastSeen }.prefix(limit).map(\.page))
    }

    private func touchCache(page: String) {
        var list = cacheEntries()
        if let idx = list.firstIndex(where: { $0.page == page }) {
            list[idx].lastSeen = Date()
        } else {
            list.append(CacheEntry(page: page, lastSeen: Date()))
        }
        if list.count > 200 {
            list = Array(list.sorted { $0.lastSeen > $1.lastSeen }.prefix(200))
        }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: cacheURL)
        }
    }

    // MARK: - Tool: list_wiki

    func listWiki() -> String {
        let url = wikiDir.appendingPathComponent("index.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "(empty wiki)"
    }

    // MARK: - Tool: read_file

    func readFile(path: String) -> String {
        let url = wikiDir.appendingPathComponent(path)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "(file not found: \(path))"
        }
        touchCache(page: path)
        return content
    }

    // MARK: - Tool: write_file

    @discardableResult
    func writeFile(path: String, content: String) throws -> String {
        let url = wikiDir.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
        touchCache(page: path)
        updateWikiIndex()
        return "ok"
    }

    // MARK: - Tool: edit_file

    @discardableResult
    func editFile(path: String, old: String, new: String) throws -> String {
        let url = wikiDir.appendingPathComponent(path)
        guard var content = try? String(contentsOf: url, encoding: .utf8) else {
            throw WikiError.fileNotFound(path)
        }
        guard content.contains(old) else {
            throw WikiError.editNotFound(path)
        }
        content = content.replacingOccurrences(of: old, with: new)
        try content.write(to: url, atomically: true, encoding: .utf8)
        touchCache(page: path)
        return "ok"
    }

    // MARK: - Tool: search_wiki

    func searchWiki(query: String) -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: wikiDir, includingPropertiesForKeys: nil
        ) else { return "(no results)" }
        let lower = query.lowercased()
        var results: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "md",
                  let content = try? String(contentsOf: url, encoding: .utf8),
                  content.lowercased().contains(lower) else { continue }
            let rel = url.path.replacingOccurrences(of: wikiDir.path + "/", with: "")
            let snippet = content.components(separatedBy: .newlines).first { !$0.isEmpty } ?? ""
            results.append("\(rel): \(snippet)")
        }
        return results.isEmpty ? "(no results)" : results.joined(separator: "\n")
    }

    // MARK: - Private

    private func ensureWikiIndex() {
        let url = wikiDir.appendingPathComponent("index.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? "# Wiki Index\n\n(empty — ispy hasn't dreamed yet)\n"
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func updateWikiIndex() {
        guard let enumerator = FileManager.default.enumerator(
            at: wikiDir, includingPropertiesForKeys: nil
        ) else { return }
        var pages: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "md", url.lastPathComponent != "index.md" else { continue }
            pages.append(url.path.replacingOccurrences(of: wikiDir.path + "/", with: ""))
        }
        pages.sort()
        let content = "# Wiki Index\n\n" + pages.map { "- [[\($0)]]" }.joined(separator: "\n") + "\n"
        try? content.write(
            to: wikiDir.appendingPathComponent("index.md"), atomically: true, encoding: .utf8
        )
    }
}

enum WikiError: LocalizedError {
    case fileNotFound(String)
    case editNotFound(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let p): "File not found: \(p)"
        case .editNotFound(let p): "Old text not found in: \(p)"
        }
    }
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ispy/ispy/WikiStore.swift
git commit -m "feat: add WikiStore with 5 agent tools, dream.json cursor, cache.json"
```

---

### Task 3: DreamLog — observable log model

**Files:**
- Create: `ispy/ispy/DreamLog.swift`

- [ ] **Step 1: Create DreamLog.swift**

```swift
// ispy/ispy/DreamLog.swift
import Foundation

struct DreamLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: timestamp)
    }
}

@Observable
@MainActor
final class DreamLog {
    private(set) var entries: [DreamLogEntry] = []

    func append(_ message: String) {
        entries.append(DreamLogEntry(timestamp: Date(), message: message))
    }

    func clear() {
        entries.removeAll()
    }
}
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ispy/ispy/DreamLog.swift
git commit -m "feat: add DreamLog observable model for streaming dream activity"
```

---

### Task 4: DreamAgent — Gemma 4 tool-calling loop

**Files:**
- Create: `ispy/ispy/DreamAgent.swift`

DreamAgent is a pure struct. It receives a `LiteRTLMEngine`, `WikiStore`, and `DreamLog` and drives the full dream session: system prompt → memory loop → GC pass.

**Token reference (all are literal strings containing these characters):**

| Constant name | String value |
|---|---|
| `turnOpen` | `<\|turn>` |
| `turnClose` | `<turn\|>` |
| `toolOpen` | `<\|tool>` |
| `toolClose` | `<tool\|>` |
| `toolCallOpen` | `<\|tool_call>` |
| `toolCallClose` | `<tool_call\|>` |
| `toolRespOpen` | `<\|tool_response>` |
| `toolRespClose` | `<tool_response\|>` |
| `strQ` | `<\|"\|>` (string delimiter, contains a literal `"`) |

In Swift source: `strQ` must use unicode escape `"<|\u{22}|>"` because a bare `"` inside a regular string literal would terminate it. All other tokens contain only `<`, `|`, `>`, and letters — no escaping needed.

- [ ] **Step 1: Create DreamAgent.swift**

```swift
// ispy/ispy/DreamAgent.swift
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
    private let maxGCIter = 30

    // String value: <|"|>  (the Gemma 4 string delimiter token)
    private let strQ = "<|\u{22}|>"

    // MARK: - Entry point

    func run(captures: [MemoryEntry], entropyPages: [String]) async throws {
        await log.append("Dream started — \(captures.count) unprocessed capture(s)")
        for (i, capture) in captures.enumerated() {
            await log.append("[\(i+1)/\(captures.count)] \(capture.timestamp.formatted(.iso8601))")
            try await processCapture(capture, entropyPages: entropyPages)
        }
        await log.append("GC pass started")
        try await runGCPass()
    }

    // MARK: - Memory loop

    private func processCapture(_ capture: MemoryEntry, entropyPages: [String]) async throws {
        try await engine.openSession(temperature: 0.3, maxTokens: 512)
        defer { engine.closeSession() }

        let systemBlock = buildMemorySystemPrompt(entropyPages: entropyPages)
        let firstInput = systemBlock +
            "<|turn>user\n" +
            "Process this memory and update the wiki. Use list_wiki to see existing pages, " +
            "read_file to inspect relevant ones, then write_file or edit_file to update. " +
            "When finished, respond with plain text only (no tool call).\n\n" +
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

    // MARK: - GC pass

    private func runGCPass() async throws {
        try await engine.openSession(temperature: 0.3, maxTokens: 512)
        defer { engine.closeSession() }

        let index = wikiStore.listWiki()
        let firstInput = buildGCSystemPrompt() +
            "<|turn>user\n" +
            "Review the wiki index and clean it up: merge pages about the same concept, " +
            "add missing [[wikilinks]] between related pages. " +
            "When finished, respond with plain text only (no tool call).\n\n" +
            "Wiki index:\n\(index)\n" +
            "<turn|>\n<|turn>model\n"

        var response = try await runTurn(firstInput)

        for _ in 0..<maxGCIter {
            let clean = stripThinking(response)
            guard let call = parseToolCall(from: clean) else { break }
            let result = executeToolCall(call)
            await log.append("GC → \(call.name)(\(shortArgs(call.args))) → \(result.preview)")
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

    private func executeToolCall(_ call: ParsedToolCall) -> ToolResult {
        do {
            let result: String
            switch call.name {
            case "list_wiki":
                result = wikiStore.listWiki()
            case "read_file":
                result = wikiStore.readFile(path: call.args["path"] ?? "")
            case "write_file":
                result = try wikiStore.writeFile(
                    path: call.args["path"] ?? "", content: call.args["content"] ?? ""
                )
            case "edit_file":
                result = try wikiStore.editFile(
                    path: call.args["path"] ?? "",
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

    private func buildMemorySystemPrompt(entropyPages: [String]) -> String {
        var s = "<|turn>system\n"
        s += "You are ispy's dreaming mind. ispy observes the world through images and maintains a personal wiki.\n\n"
        s += "Wiki rules:\n"
        s += "- Pages cover observable things only: places, recurring objects, themes, moods.\n"
        s += "- Never name people — use descriptive labels like 'person in red jacket'.\n"
        s += "- Each page: H1 title, description paragraph, ## Connections section with [[wikilinks]].\n"
        s += "- File paths use kebab-case: places/coffee-shop.md, themes/morning-light.md.\n\n"

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

    private func buildGCSystemPrompt() -> String {
        var s = "<|turn>system\n"
        s += "You are ispy's memory organizer. Your job: merge duplicate wiki pages and add missing [[wikilinks]].\n"
        s += "Rules: only consolidate existing pages, don't create new ones. File paths use kebab-case.\n\n"
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
        // Match: key:<|"|>value<|"|>
        // In regex source: key:<\|"\|>(.*?)<\|"\|>
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
```

- [ ] **Step 2: Build in Xcode (Cmd+B)**

Expected: Build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add ispy/ispy/DreamAgent.swift
git commit -m "feat: add DreamAgent with Gemma 4 tool-calling loop and GC pass"
```

---

### Task 5: GemmaVisionService patch + DreamService orchestrator

**Files:**
- Modify: `ispy/ispy/GemmaVisionService.swift` — expose `engine` as internal
- Create: `ispy/ispy/DreamService.swift`

DreamService is `@MainActor`. It checks that Gemma is loaded, collects unprocessed captures, selects entropy pages, runs DreamAgent, and writes `lastDreamed` when complete.

- [ ] **Step 1: Expose engine in GemmaVisionService**

In `ispy/ispy/GemmaVisionService.swift`, change line 21:

```swift
// Before:
private var engine: LiteRTLMEngine?

// After:
var engine: LiteRTLMEngine?
```

Build with Cmd+B. Expected: Build succeeds.

- [ ] **Step 2: Create DreamService.swift**

```swift
// ispy/ispy/DreamService.swift
import Foundation
import BackgroundTasks

@Observable
@MainActor
final class DreamService {
    private(set) var isRunning = false
    private(set) var lastError: String?

    private let wikiStore: WikiStore
    private let log: DreamLog
    private let gemmaService: GemmaVisionService

    init(wikiStore: WikiStore, log: DreamLog, gemmaService: GemmaVisionService) {
        self.wikiStore = wikiStore
        self.log = log
        self.gemmaService = gemmaService
    }

    func dream(memoryStore: MemoryStore) async {
        guard !isRunning else { return }

        guard gemmaService.state == .ready, let engine = gemmaService.engine else {
            lastError = "Gemma model not loaded — open Capture tab and load the model first"
            return
        }

        isRunning = true
        lastError = nil
        log.clear()

        defer { isRunning = false }

        do {
            let captures = unprocessedCaptures(memoryStore: memoryStore)
            guard !captures.isEmpty else {
                await log.append("No new memories to process")
                return
            }

            let entropyPages = selectEntropyPages(limit: 2)
            for page in entropyPages {
                await log.append("Surfacing old memory: \(page)")
            }

            let agent = DreamAgent(engine: engine, wikiStore: wikiStore, log: log)
            try await agent.run(captures: captures, entropyPages: entropyPages)
            try wikiStore.markDreamed()
        } catch {
            lastError = error.localizedDescription
            await log.append("Error: \(error.localizedDescription)")
        }
    }

    // MARK: - BGProcessingTask scheduling

    static let bgTaskIdentifier = "com.ispy.dream"

    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgTaskIdentifier, using: nil
        ) { [weak self] task in
            guard let self, let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                // Background dreams need a MemoryStore — create a temporary one
                let memoryStore = MemoryStore()
                await self.dream(memoryStore: memoryStore)
                task.setTaskCompleted(success: self.lastError == nil)
                self.scheduleNextDream()
            }
            task.expirationHandler = {
                task.setTaskCompleted(success: false)
            }
        }
    }

    func scheduleNextDream() {
        let request = BGProcessingTaskRequest(identifier: Self.bgTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true
        request.earliestBeginDate = Calendar.current.date(
            byAdding: .hour, value: 22, to: Date()
        )
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Private helpers

    private func unprocessedCaptures(memoryStore: MemoryStore) -> [MemoryEntry] {
        let cursor = wikiStore.lastDreamed ?? .distantPast
        return memoryStore.entries.filter { $0.timestamp > cursor }
    }

    private func selectEntropyPages(limit: Int) -> [String] {
        let pages = wikiStore.oldestCachePages(limit: limit * 3)
        guard !pages.isEmpty else { return [] }
        return Array(pages.shuffled().prefix(limit))
    }
}
```

- [ ] **Step 3: Build in Xcode (Cmd+B)**

Expected: Build succeeds. (BackgroundTasks framework is already linked; if not, add it in Xcode under Target → Frameworks, Libraries.)

- [ ] **Step 4: Commit**

```bash
git add ispy/ispy/GemmaVisionService.swift ispy/ispy/DreamService.swift
git commit -m "feat: add DreamService orchestrator with entropy injection and BGProcessingTask"
```

---

### Task 6: DreamView UI + RootView wiring + BGTask registration

**Files:**
- Create: `ispy/ispy/DreamView.swift`
- Modify: `ispy/ispy/RootView.swift`
- Modify: `ispy/ispy/ispyApp.swift` (or wherever `@main` lives — register BGTask)
- Modify: `ispy/ispy/Info.plist` — add `BGTaskSchedulerPermittedIdentifiers`

- [ ] **Step 1: Create DreamView.swift**

```swift
// ispy/ispy/DreamView.swift
import SwiftUI

struct DreamView: View {
    let dreamService: DreamService
    let dreamLog: DreamLog
    let memoryStore: MemoryStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBanner
                    .padding(.horizontal)
                    .padding(.top, 8)

                if dreamLog.entries.isEmpty {
                    ContentUnavailableView(
                        "No dream yet",
                        systemImage: "moon.stars",
                        description: Text("Tap Dream to start processing memories.")
                    )
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(dreamLog.entries) { entry in
                                    Text("[\(entry.timeString)] \(entry.message)")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .id(entry.id)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .onChange(of: dreamLog.entries.count) { _, _ in
                            if let last = dreamLog.entries.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Dream")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Dream") {
                        Task { await dreamService.dream(memoryStore: memoryStore) }
                    }
                    .disabled(dreamService.isRunning)
                }
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if dreamService.isRunning {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Dreaming…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
        } else if let error = dreamService.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.bottom, 4)
        }
    }
}
```

- [ ] **Step 2: Update RootView.swift**

```swift
// ispy/ispy/RootView.swift
import SwiftUI

struct RootView: View {
    @State private var gemmaService = GemmaVisionService()
    @State private var memoryStore = MemoryStore()
    @State private var dreamLog = DreamLog()

    private var wikiStore: WikiStore {
        WikiStore(memoryDir: memoryStore.memoryDir)
    }

    @State private var dreamService: DreamService?

    var body: some View {
        TabView {
            CaptureView(gemmaService: gemmaService, memoryStore: memoryStore)
                .tabItem { Label("Capture", systemImage: "camera.fill") }
            MemoryView(memoryStore: memoryStore)
                .tabItem { Label("Memory", systemImage: "brain") }
            if let ds = dreamService {
                DreamView(dreamService: ds, dreamLog: dreamLog, memoryStore: memoryStore)
                    .tabItem { Label("Dream", systemImage: "moon.stars") }
            }
        }
        .task {
            await gemmaService.start()
            let ws = WikiStore(memoryDir: memoryStore.memoryDir)
            dreamService = DreamService(wikiStore: ws, log: dreamLog, gemmaService: gemmaService)
            dreamService?.scheduleNextDream()
        }
    }
}
```

Wait — `WikiStore` is not `@Observable` and creating two instances will cause issues. Fix: store `wikiStore` as a `@State`:

```swift
// ispy/ispy/RootView.swift
import SwiftUI

struct RootView: View {
    @State private var gemmaService = GemmaVisionService()
    @State private var memoryStore = MemoryStore()
    @State private var dreamLog = DreamLog()
    @State private var wikiStore: WikiStore?
    @State private var dreamService: DreamService?

    var body: some View {
        TabView {
            CaptureView(gemmaService: gemmaService, memoryStore: memoryStore)
                .tabItem { Label("Capture", systemImage: "camera.fill") }
            MemoryView(memoryStore: memoryStore)
                .tabItem { Label("Memory", systemImage: "brain") }
            if let ds = dreamService {
                DreamView(dreamService: ds, dreamLog: dreamLog, memoryStore: memoryStore)
                    .tabItem { Label("Dream", systemImage: "moon.stars") }
            }
        }
        .task {
            await gemmaService.start()
            let ws = WikiStore(memoryDir: memoryStore.memoryDir)
            wikiStore = ws
            let ds = DreamService(wikiStore: ws, log: dreamLog, gemmaService: gemmaService)
            dreamService = ds
            ds.scheduleNextDream()
        }
    }
}
```

- [ ] **Step 3: Add BGTaskSchedulerPermittedIdentifiers to Info.plist**

In Xcode, open `ispy/ispy/Info.plist`. Add a new key:
- Key: `BGTaskSchedulerPermittedIdentifiers`
- Type: Array
- Item 0 (String): `com.ispy.dream`

Or add via the raw XML editor:
```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.ispy.dream</string>
</array>
```

- [ ] **Step 4: Register BGTask in app entry point**

Find the `@main` App struct (likely `ispyApp.swift`). Read its current contents, then update:

```swift
// ispy/ispy/ispyApp.swift
import SwiftUI
import BackgroundTasks

@main
struct ispyApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
```

The `BGTaskScheduler` registration happens in `DreamService.registerBackgroundTask()`. Call it from `RootView.task` after creating `dreamService`:

In `RootView.swift`, after `ds.scheduleNextDream()`, add:
```swift
ds.registerBackgroundTask()
```

- [ ] **Step 5: Build in Xcode (Cmd+B)**

Expected: Build succeeds. Three tabs appear: Capture, Memory, Dream.

- [ ] **Step 6: Run on device — tap Dream tab**

Expected:
- Dream tab shows "No dream yet" with moon icon
- "Dream" button is in the toolbar
- Tapping Dream with Gemma loaded starts the agent loop
- Log entries appear live, scrolling to bottom

- [ ] **Step 7: Commit**

```bash
git add ispy/ispy/DreamView.swift ispy/ispy/RootView.swift ispy/ispy/ispyApp.swift
git commit -m "feat: add DreamView tab with live log, wire up DreamService and BGProcessingTask"
```

---

## Self-Review

**Spec coverage check:**

| Requirement | Task |
|---|---|
| raw/YYYY-MM-DD/ filesystem | Task 1 |
| wiki/ with places/themes/objects | Task 2 |
| dream.json lastDreamed cursor | Task 2 |
| cache.json recently-accessed pages | Task 2 |
| 5 agent tools | Task 2 |
| Streaming log entries | Task 3, 4 |
| Iterative tool-calling loop | Task 4 |
| Entropy injection (old wiki pages) | Task 4, 5 |
| GC pass (merge + strengthen links) | Task 4 |
| Dream button | Task 6 |
| BGProcessingTask scheduling | Task 5, 6 |
| Single-line log display | Task 6 |
| lastDreamed written on completion | Task 5 |

**No placeholders found.**

**Type consistency:** All method names (`wikiStore.readFile`, `wikiStore.writeFile`, `wikiStore.editFile`, `wikiStore.searchWiki`, `wikiStore.listWiki`, `wikiStore.markDreamed`, `wikiStore.oldestCachePages`) are defined in Task 2 and used consistently in Tasks 4 and 5. `DreamLog.append`, `DreamLog.clear` defined in Task 3, used in Tasks 4 and 5. `DreamAgent.run` defined in Task 4, called in Task 5.

**Known limitation:** `parseArgs` uses a regex matching `key:<|"|>value<|"|>` patterns. If the model emits a numeric argument without string delimiters (e.g. `count:5`), it won't be parsed. All 5 tools only need string args, so this is safe for the current tool set.

Sources:
- [chat_template.jinja · google/gemma-4-E4B-it](https://huggingface.co/google/gemma-4-E4B-it/blob/main/chat_template.jinja)
- [gemma4_jinja — custom Gemma 4 chat template](https://github.com/asf0/gemma4_jinja)
- [Gemma 4 specialized parser PR — llama.cpp](https://github.com/ggml-org/llama.cpp/pull/21418)
- [Fixed Gemma 4 chat template gist](https://gist.github.com/bbrowning/c584eb2dbd79e4cc9ecedf92eee2d135)
