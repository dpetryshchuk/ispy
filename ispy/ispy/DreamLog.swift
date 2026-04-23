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

struct RawTurn: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let input: String
    let output: String
}

struct DreamSession: Identifiable, Codable {
    let id: UUID
    let startedAt: Date
    let entries: [Entry]
    var rawTurns: [RawTurn]

    struct Entry: Codable {
        let timestamp: Date
        let message: String
    }

    init(id: UUID, startedAt: Date, entries: [Entry], rawTurns: [RawTurn] = []) {
        self.id = id; self.startedAt = startedAt
        self.entries = entries; self.rawTurns = rawTurns
    }
}

@Observable
@MainActor
final class DreamLog {
    private(set) var entries: [DreamLogEntry] = []
    private(set) var rawTurns: [RawTurn] = []

    private static let logsDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("dreamlogs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func append(_ message: String) {
        entries.append(DreamLogEntry(timestamp: Date(), message: message))
    }

    func appendRawTurn(input: String, output: String) {
        rawTurns.append(RawTurn(id: UUID(), timestamp: Date(), input: input, output: output))
    }

    func clear() {
        entries.removeAll()
        rawTurns.removeAll()
    }

    func save() {
        guard !entries.isEmpty else { return }
        let session = DreamSession(
            id: UUID(),
            startedAt: entries.first?.timestamp ?? Date(),
            entries: entries.map { DreamSession.Entry(timestamp: $0.timestamp, message: $0.message) },
            rawTurns: rawTurns
        )
        let url = Self.logsDir.appendingPathComponent("\(session.id.uuidString).json")
        if let data = try? JSONEncoder().encode(session) { try? data.write(to: url) }
    }

    func savedSessions() -> [DreamSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.logsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> DreamSession? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(DreamSession.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }
}
