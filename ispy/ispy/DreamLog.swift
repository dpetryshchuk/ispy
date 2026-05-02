import Foundation

// MARK: - Event

struct StepEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let kind: Kind

    init(kind: Kind) {
        id = UUID()
        timestamp = Date()
        self.kind = kind
    }

    enum Kind: Codable {
        case tool(name: String, args: String, preview: String)
        case llm(preview: String)
        case info(String)
        case error(String)

        private enum CodingKeys: String, CodingKey { case type, name, args, preview, message }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "tool": self = .tool(
                name: try c.decode(String.self, forKey: .name),
                args: try c.decode(String.self, forKey: .args),
                preview: try c.decode(String.self, forKey: .preview))
            case "llm":  self = .llm(preview: try c.decode(String.self, forKey: .preview))
            case "error": self = .error(try c.decode(String.self, forKey: .message))
            default:     self = .info((try? c.decode(String.self, forKey: .message)) ?? "")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .tool(let n, let a, let p):
                try c.encode("tool", forKey: .type); try c.encode(n, forKey: .name)
                try c.encode(a, forKey: .args); try c.encode(p, forKey: .preview)
            case .llm(let p):
                try c.encode("llm", forKey: .type); try c.encode(p, forKey: .preview)
            case .info(let m):
                try c.encode("info", forKey: .type); try c.encode(m, forKey: .message)
            case .error(let m):
                try c.encode("error", forKey: .type); try c.encode(m, forKey: .message)
            }
        }
    }
}

// MARK: - Step

struct DreamStep: Identifiable, Codable {
    let id: UUID
    let label: String
    let startedAt: Date
    var endedAt: Date?
    var succeeded: Bool?
    var errorMessage: String?
    var events: [StepEvent]
    var rawTurns: [RawTurn]

    init(label: String) {
        id = UUID(); self.label = label; startedAt = Date(); events = []; rawTurns = []
    }

    var isRunning: Bool { endedAt == nil }
    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
    var toolCount: Int { events.filter { if case .tool = $0.kind { true } else { false } }.count }
    var llmCount:  Int { events.filter { if case .llm  = $0.kind { true } else { false } }.count }

    var lastEventPreview: String? {
        events.last.map { e in
            switch e.kind {
            case .tool(let n, _, let p): "\(n) → \(p)"
            case .llm(let p):           p
            case .info(let m):          m
            case .error(let m):         "⚠ \(m)"
            }
        }
    }
}

// MARK: - Phase

struct DreamPhase: Identifiable, Codable {
    let id: UUID
    let label: String
    let startedAt: Date
    var endedAt: Date?
    var succeeded: Bool?
    var steps: [DreamStep]

    init(label: String) {
        id = UUID(); self.label = label; startedAt = Date(); steps = []
    }

    var isRunning: Bool { endedAt == nil }
    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
    var totalTools: Int { steps.reduce(0) { $0 + $1.toolCount } }
    var runningStep: DreamStep? { steps.first(where: { $0.isRunning }) }
}

// MARK: - Raw turn (unchanged shape)

struct RawTurn: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let input: String
    let output: String
}

// MARK: - Persisted session

struct DreamSession: Identifiable, Codable {
    let id: UUID
    let startedAt: Date
    let phases: [DreamPhase]

    init(id: UUID, startedAt: Date, phases: [DreamPhase]) {
        self.id = id; self.startedAt = startedAt; self.phases = phases
    }

    // Custom decode — old sessions lack "phases", decode gracefully
    enum CodingKeys: String, CodingKey { case id, startedAt, phases }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        phases = (try? c.decode([DreamPhase].self, forKey: .phases)) ?? []
    }

    // Computed flat entries for MindView narrative card backward compat
    var entries: [Entry] {
        phases.flatMap { phase in
            [Entry(timestamp: phase.startedAt, message: phase.label)] +
            phase.steps.flatMap { step in
                step.events.compactMap { e -> Entry? in
                    switch e.kind {
                    case .info(let m):          return Entry(timestamp: e.timestamp, message: m)
                    case .tool(let n, _, let p): return Entry(timestamp: e.timestamp, message: "\(n) → \(p)")
                    case .error(let m):          return Entry(timestamp: e.timestamp, message: "⚠ \(m)")
                    default: return nil
                    }
                }
            }
        }
    }

    struct Entry: Codable {
        let timestamp: Date
        let message: String
    }
}

// MARK: - Backward compat entry type (used by MindView live banner)

struct DreamLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String

    var timeString: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: timestamp)
    }
}

// MARK: - Live log

@Observable
@MainActor
final class DreamLog {
    private(set) var phases: [DreamPhase] = []
    private(set) var sessionStartedAt: Date? = nil

    private var currentPhaseIdx: Int? = nil
    private var currentStepIdx: Int? = nil

    private static let logsDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("dreamlogs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Backward compat (MindView live banner)

    var entries: [DreamLogEntry] {
        phases.flatMap { phase in
            phase.steps.flatMap { step in
                step.events.compactMap { e -> DreamLogEntry? in
                    switch e.kind {
                    case .info(let m):          return DreamLogEntry(timestamp: e.timestamp, message: m)
                    case .tool(let n, _, let p): return DreamLogEntry(timestamp: e.timestamp, message: "\(n) → \(p)")
                    case .error(let m):          return DreamLogEntry(timestamp: e.timestamp, message: "⚠ \(m)")
                    default: return nil
                    }
                }
            }
        }
    }

    func append(_ message: String) { logInfo(message) }

    // MARK: - Session lifecycle

    func clear() {
        phases = []; sessionStartedAt = Date()
        currentPhaseIdx = nil; currentStepIdx = nil
    }

    // MARK: - Phase management

    func beginPhase(_ label: String) {
        sealCurrentPhase(success: true)
        phases.append(DreamPhase(label: label))
        currentPhaseIdx = phases.count - 1
        currentStepIdx = nil
    }

    func endPhase(success: Bool) {
        sealCurrentStep(success: success)
        guard let idx = currentPhaseIdx else { return }
        phases[idx].endedAt = Date()
        phases[idx].succeeded = success
        currentPhaseIdx = nil; currentStepIdx = nil
    }

    // MARK: - Step management

    func beginStep(_ label: String) {
        sealCurrentStep(success: true)
        guard let pi = currentPhaseIdx else { return }
        phases[pi].steps.append(DreamStep(label: label))
        currentStepIdx = phases[pi].steps.count - 1
    }

    func endStep(success: Bool, error: String? = nil) {
        guard let pi = currentPhaseIdx, let si = currentStepIdx else { return }
        phases[pi].steps[si].endedAt = Date()
        phases[pi].steps[si].succeeded = success
        phases[pi].steps[si].errorMessage = error
        currentStepIdx = nil
    }

    // MARK: - Event logging

    func logTool(_ name: String, args: String, preview: String) {
        addEvent(.tool(name: name, args: args, preview: preview))
    }

    func logLLM(_ preview: String) {
        let p = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        addEvent(.llm(preview: p))
    }

    func logInfo(_ message: String) { addEvent(.info(message)) }
    func logError(_ message: String) { addEvent(.error(message)) }

    func appendRawTurn(input: String, output: String) {
        guard let pi = currentPhaseIdx, let si = currentStepIdx else { return }
        phases[pi].steps[si].rawTurns.append(
            RawTurn(id: UUID(), timestamp: Date(), input: input, output: output)
        )
    }

    // MARK: - Persistence

    func save() {
        sealCurrentPhase(success: true)
        guard !phases.isEmpty else { return }
        let session = DreamSession(id: UUID(), startedAt: sessionStartedAt ?? Date(), phases: phases)
        let url = Self.logsDir.appendingPathComponent("\(session.id.uuidString).json")
        if let data = try? JSONEncoder().encode(session) { try? data.write(to: url) }
    }

    func savedSessions() -> [DreamSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.logsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url -> DreamSession? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(DreamSession.self, from: data)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Private

    private func addEvent(_ kind: StepEvent.Kind) {
        guard let pi = currentPhaseIdx, let si = currentStepIdx else { return }
        phases[pi].steps[si].events.append(StepEvent(kind: kind))
    }

    private func sealCurrentStep(success: Bool) {
        guard let pi = currentPhaseIdx, let si = currentStepIdx,
              phases[pi].steps[si].endedAt == nil else { return }
        phases[pi].steps[si].endedAt = Date()
        phases[pi].steps[si].succeeded = success
        currentStepIdx = nil
    }

    private func sealCurrentPhase(success: Bool) {
        guard let pi = currentPhaseIdx, phases[pi].endedAt == nil else { return }
        sealCurrentStep(success: success)
        phases[pi].endedAt = Date()
        phases[pi].succeeded = success
        currentPhaseIdx = nil
    }
}
