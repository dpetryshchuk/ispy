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

    func delete(id: UUID) throws {
        guard let entry = entries.first(where: { $0.id == id }) else {
            throw MemoryError.entryNotFound
        }
        let photosDir = dayPhotosDir(for: entry.timestamp)
        try? FileManager.default.removeItem(
            at: photosDir.appendingPathComponent(entry.photoFilename)
        )
        let dir = dayDirectory(for: entry.timestamp)
        var dayEntries = loadDayEntries(dayDir: dir)
        dayEntries.removeAll { $0.id == id }
        if dayEntries.isEmpty {
            try? FileManager.default.removeItem(at: dir)
        } else {
            try writeDayEntries(dayEntries, dayDir: dir)
        }
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