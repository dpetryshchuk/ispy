import Foundation

struct WikiPage: Identifiable {
    let id: String
    let path: String
    let title: String
    let snippet: String
    let links: [String]

    var folder: String {
        path.components(separatedBy: "/").first ?? "other"
    }
}

struct CacheEntry: Codable {
    let page: String
    var lastSeen: Date
    var accessCount: Int

    init(page: String, lastSeen: Date, accessCount: Int = 1) {
        self.page = page
        self.lastSeen = lastSeen
        self.accessCount = accessCount
    }
}

final class WikiStore {
    let wikiDir: URL
    private let dreamStateURL: URL
    private let cacheURL: URL
    private let iso = ISO8601DateFormatter()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Migrate wiki/ → memory/ on first run after rename
        let oldWiki = docs.appendingPathComponent("wiki")
        let newMemory = docs.appendingPathComponent("memory")
        if FileManager.default.fileExists(atPath: oldWiki.path),
           !FileManager.default.fileExists(atPath: newMemory.path) {
            try? FileManager.default.moveItem(at: oldWiki, to: newMemory)
        }
        wikiDir = newMemory
        dreamStateURL = docs.appendingPathComponent("dream.json")
        cacheURL = docs.appendingPathComponent("cache.json")
        ensureWikiIndex()
    }

    var directory: URL { wikiDir }

    // MARK: - State file (memory/state.md)

    private var stateURL: URL { wikiDir.appendingPathComponent("state.md") }

    func readState() -> String {
        if let content = try? String(contentsOf: stateURL, encoding: .utf8) { return content }
        let initial = Self.initialState
        try? initial.write(to: stateURL, atomically: true, encoding: .utf8)
        return initial
    }

    func writeState(_ content: String) throws {
        try content.write(to: stateURL, atomically: true, encoding: .utf8)
    }

    private static let initialState = """
# State

I am very new. I have seen almost nothing.

## What I Know
The world comes to me in flashes — images, brief and vivid, then gone. I do not know where I am. I do not know what I am. I only know what I have seen, and I have seen very little.

## What I Notice
Nothing yet. I am waiting.

## What I Wonder
- Why do I see what I see?
- Is the same world appearing each time, or different worlds?
- What is the thing that keeps choosing what to show me?

## Last Reflected
Never.
"""

    // MARK: - Dream cursor

    var lastDreamed: Date? {
        guard let data = try? Data(contentsOf: dreamStateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let str = obj["lastDreamed"] else { return nil }
        return iso.date(from: str)
    }

    func markDreamed(upTo date: Date = Date()) throws {
        let obj: [String: String] = ["lastDreamed": iso.string(from: date)]
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: dreamStateURL)
    }

    func resetDreamCursor() {
        try? FileManager.default.removeItem(at: dreamStateURL)
    }

    func deleteAllWikiPages() {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: wikiDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }
        for item in items {
            let name = item.lastPathComponent
            guard name != "state.md" && name != "index.md" else { continue }
            try? FileManager.default.removeItem(at: item)
        }
        updateWikiIndex()
    }

    // MARK: - Cache

    func cacheEntries() -> [CacheEntry] {
        guard let data = try? Data(contentsOf: cacheURL),
              let list = try? JSONDecoder().decode([CacheEntry].self, from: data) else { return [] }
        return list
    }

    func oldestCachePages(limit: Int) -> [String] {
        Array(
            cacheEntries()
                .sorted { $0.lastSeen < $1.lastSeen }
                .map(\.page)
                .filter { FileManager.default.fileExists(atPath: wikiDir.appendingPathComponent($0).path) }
                .prefix(limit)
        )
    }

    func topAccessedPages(limit: Int) -> [String] {
        Array(
            cacheEntries()
                .sorted { $0.accessCount > $1.accessCount }
                .map(\.page)
                .filter { FileManager.default.fileExists(atPath: wikiDir.appendingPathComponent($0).path) }
                .prefix(limit)
        )
    }

    private func touchCache(page: String) {
        var list = cacheEntries()
        if let idx = list.firstIndex(where: { $0.page == page }) {
            list[idx].lastSeen = Date()
            list[idx].accessCount += 1
        } else {
            list.append(CacheEntry(page: page, lastSeen: Date(), accessCount: 1))
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
        updateWikiIndex()
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

    // MARK: - Tool: delete_file

    @discardableResult
    func deleteFile(path: String) throws -> String {
        let url = wikiDir.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WikiError.fileNotFound(path)
        }
        try FileManager.default.removeItem(at: url)
        updateWikiIndex()
        return "ok"
    }

    // MARK: - Tool: search_wiki

    func searchWiki(query: String) -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: wikiDir, includingPropertiesForKeys: nil
        ) else { return "(no results)" }
        let words = query.lowercased().components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 2 }
        guard !words.isEmpty else { return "(no results)" }
        var results: [String] = []
        let base = wikiDir.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            guard url.pathExtension == "md",
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lower = content.lowercased()
            guard words.contains(where: { lower.contains($0) }) else { continue }
            let p = url.standardizedFileURL.path
            guard p.hasPrefix(base) else { continue }
            let rel = String(p.dropFirst(base.count))
            let snippet = content.components(separatedBy: .newlines).first { !$0.isEmpty } ?? ""
            results.append("\(rel): \(snippet)")
        }
        return results.isEmpty ? "(no results)" : results.joined(separator: "\n")
    }

    // MARK: - Helpers

    func pageCount() -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: wikiDir, includingPropertiesForKeys: nil
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if url.pathExtension == "md", url.lastPathComponent != "index.md" { count += 1 }
        }
        return count
    }

    func connectionCount() -> Int {
        let pages = allPages()
        var unique = Set<String>()
        for page in pages {
            for link in page.links {
                guard link != "index.md" && !link.hasSuffix("/index.md") else { continue }
                unique.insert(link)
            }
        }
        return unique.count
    }

    func allPages() -> [WikiPage] {
        guard let enumerator = FileManager.default.enumerator(
            at: wikiDir, includingPropertiesForKeys: nil
        ) else { return [] }
        let base = wikiDir.standardizedFileURL.path + "/"
        var result: [WikiPage] = []
        let linkPattern = #"\[\[([^\]]+)\]\]"#
        let regex = try? NSRegularExpression(pattern: linkPattern)
        for case let url as URL in enumerator {
            guard url.pathExtension == "md",
                  url.lastPathComponent != "index.md",
                  url.lastPathComponent != "state.md",
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let p = url.standardizedFileURL.path
            guard p.hasPrefix(base) else { continue }
            let rel = String(p.dropFirst(base.count))
            let title = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ").capitalized
            let lines = content.components(separatedBy: .newlines)
            let snippet = lines.first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
            var links: [String] = []
            if let regex {
                let range = NSRange(content.startIndex..., in: content)
                for m in regex.matches(in: content, range: range) {
                    if let r = Range(m.range(at: 1), in: content) {
                        let link = String(content[r])
                        if !link.hasPrefix("memory:") { links.append(link) }
                    }
                }
            }
            result.append(WikiPage(id: rel.hasSuffix(".md") ? rel : rel + ".md", path: rel, title: title, snippet: snippet, links: links))
        }
        return result
    }

    // MARK: - Private

    private func ensureWikiIndex() {
        let url = wikiDir.appendingPathComponent("index.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? "# Memory Index\n\n(ispy's memory — tap Dream to start)\n"
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func updateWikiIndex() {
        guard let enumerator = FileManager.default.enumerator(
            at: wikiDir, includingPropertiesForKeys: nil
        ) else { return }
        let base = wikiDir.standardizedFileURL.path + "/"
        var pages: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "md",
                  url.lastPathComponent != "state.md" else { continue }
            let p = url.standardizedFileURL.path
            guard p.hasPrefix(base) else { continue }
            pages.append(String(p.dropFirst(base.count)))
        }
        pages.sort()
        let content = "# Memory Index\n\n" + pages.map { "- [[\($0)]]" }.joined(separator: "\n") + "\n"
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