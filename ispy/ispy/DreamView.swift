import SwiftUI

struct DreamView: View {
    let dreamService: DreamService
    let dreamLog: DreamLog
    let memoryStore: MemoryStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBanner
                    .padding()

                if dreamLog.entries.isEmpty {
                    emptyState
                } else {
                    logView
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

    private var statusBanner: some View {
        Group {
            if dreamService.isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Dreaming…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let error = dreamService.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No dream yet",
            systemImage: "moon.stars",
            description: Text("Tap Dream to start.")
        )
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(dreamLog.entries) { entry in
                        Text("[\(entry.timeString)] \(entry.message)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
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