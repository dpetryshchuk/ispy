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