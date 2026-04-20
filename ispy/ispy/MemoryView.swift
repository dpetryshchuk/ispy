import SwiftUI

struct MemoryView: View {
    let memoryStore: MemoryStore
    @State private var selectedEntry: MemoryEntry?

    var body: some View {
        NavigationStack {
            Group {
                if memoryStore.entries.isEmpty {
                    ContentUnavailableView(
                        "No memories yet",
                        systemImage: "brain",
                        description: Text("Capture and analyze a photo to create your first memory.")
                    )
                } else {
                    List(memoryStore.entries.reversed()) { entry in
                        Button { selectedEntry = entry } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.timestamp, format: .dateTime.day().month().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(entry.description.components(separatedBy: .newlines).first ?? "")
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Memory")
            .sheet(item: $selectedEntry) { entry in
                MemoryDetailView(entry: entry, photoURL: memoryStore.photoURL(for: entry))
            }
        }
    }
}

struct MemoryDetailView: View {
    let entry: MemoryEntry
    let photoURL: URL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let image = UIImage(contentsOfFile: photoURL.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.timestamp, format: .dateTime.weekday().day().month().year().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.description)
                }
                .padding(.horizontal)
            }
        }
    }
}
