import Foundation
import UIKit

struct MemoryEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let description: String
    let photoFilename: String
}

enum MemoryError: Error {
    case invalidImage
}

@Observable
final class MemoryStore {
    private(set) var entries: [MemoryEntry] = []

    private let photosDir: URL
    private let indexURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let memoryDir = docs.appendingPathComponent("memory")
        photosDir = memoryDir.appendingPathComponent("photos")
        indexURL = memoryDir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        load()
    }

    func save(image: UIImage, description: String) throws {
        let id = UUID()
        let filename = "\(id.uuidString).jpg"
        guard let data = image.jpegData(compressionQuality: 0.8) else {
            throw MemoryError.invalidImage
        }
        try data.write(to: photosDir.appendingPathComponent(filename))
        let entry = MemoryEntry(id: id, timestamp: Date(), description: description, photoFilename: filename)
        entries.append(entry)
        try writeIndex()
    }

    func photoURL(for entry: MemoryEntry) -> URL {
        photosDir.appendingPathComponent(entry.photoFilename)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        entries = (try? JSONDecoder().decode([MemoryEntry].self, from: data)) ?? []
    }

    private func writeIndex() throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: indexURL)
    }
}
