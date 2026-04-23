import SwiftUI
import UIKit

struct MemoryView: View {
    let memoryStore: MemoryStore
    let lastDreamed: Date?
    @State private var selectedEntry: MemoryEntry?

    var body: some View {
        NavigationStack {
            Group {
                if memoryStore.entries.isEmpty {
                    emptyView
                } else {
                    listView
                }
            }
            .navigationTitle("Feed")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !memoryStore.entries.isEmpty {
                        Text("\(memoryStore.entries.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .sheet(item: $selectedEntry) { entry in
                MemoryDetailView(entry: entry, photoURL: memoryStore.photoURL(for: entry)) {
                    try? memoryStore.delete(id: entry.id)
                    selectedEntry = nil
                }
            }
        }
    }

    private var emptyView: some View {
        ContentUnavailableView("Nothing here yet", systemImage: "camera", description: Text("Capture your first photo."))
    }

    private var listView: some View {
        List {
            ForEach(Array(memoryStore.entries.reversed())) { entry in
                Button { selectedEntry = entry } label: {
                    HStack(spacing: 10) {
                        let processed = lastDreamed.map { entry.timestamp <= $0 } ?? false
                        Circle()
                            .fill(processed ? Color.purple.opacity(0.7) : Color.secondary.opacity(0.2))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.timestamp, format: .dateTime.day().month().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.description.components(separatedBy: .newlines).first ?? "")
                                .lineLimit(2)
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { try? memoryStore.delete(id: entry.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

struct MemoryDetailView: View {
    let entry: MemoryEntry
    let photoURL: URL
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let image = UIImage(contentsOfFile: photoURL.path) {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                    Text(entry.timestamp, format: .dateTime.weekday().day().month().year().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                    Text(entry.description)
                    if let dream = entry.dreamDescription {
                        Text(dream).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Memory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                }
            }
        }
    }
}