import SwiftUI

struct MindView: View {
    let wikiStore: WikiStore
    let memoryStore: MemoryStore
    let dreamService: DreamService
    let dreamLog: DreamLog
    let chatService: ChatService
    let gemmaService: GemmaVisionService

    @State private var selectedPage: WikiPage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    knowledgeSection
                    dreamNarrativeSection
                }
            }
            .navigationTitle("Mind")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        ChatView(chatService: chatService, gemmaService: gemmaService)
                    } label: {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await dreamService.dream(memoryStore: memoryStore) }
                    } label: {
                        if dreamService.isRunning {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("Dream")
                        }
                    }
                    .disabled(dreamService.isRunning)
                }
            }
            .sheet(item: $selectedPage) { page in
                WikiPageView(page: page, wikiStore: wikiStore, memoryStore: memoryStore) {
                    selectedPage = $0
                }
            }
        }
    }

    // MARK: - Knowledge Graph Hero

    private var knowledgeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Knowledge")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 16)

            WikiGraphView(wikiStore: wikiStore) { selectedPage = $0 }
                .frame(height: 320)

            Divider()
                .padding(.top, 8)
        }
    }

    // MARK: - Dream Narrative

    private var dreamNarrativeSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("What ispy thought about")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                NavigationLink {
                    DreamHistoryView(dreamLog: dreamLog, dreamService: dreamService, memoryStore: memoryStore)
                } label: {
                    Text("All sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.top, 20)

            if let error = dreamService.lastError, !dreamService.isRunning {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            if dreamService.isRunning {
                activeDreamSection
            }

            let sessions = recentSessions
            if sessions.isEmpty && !dreamService.isRunning {
                Text("No dreams yet. Tap Dream to start.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal)
            } else {
                ForEach(sessions) { session in
                    DreamNarrativeCard(session: session)
                }
            }
        }
        .padding(.bottom, 48)
    }

    private var activeDreamSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.75)
                Text("Dreaming now")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
            .padding(.horizontal)

            let recent = Array(dreamLog.entries.suffix(8))
            ForEach(recent) { entry in
                NarrativeEntryRow(timestamp: entry.timeString, message: entry.message)
            }

            Divider().padding(.top, 4)
        }
    }

    private var recentSessions: [DreamSession] {
        Array(dreamLog.savedSessions().prefix(5))
    }
}

// MARK: - Narrative Entry Row

private struct NarrativeEntryRow: View {
    let timestamp: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timestamp)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)
                .padding(.top, 3)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal)
    }
}

// MARK: - Dream Narrative Card

struct DreamNarrativeCard: View {
    let session: DreamSession
    @State private var expanded = false

    private let previewCount = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.startedAt, format: .dateTime.weekday(.wide).month().day())
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            let displayEntries = expanded ? session.entries : Array(session.entries.prefix(previewCount))

            ForEach(displayEntries, id: \.timestamp) { entry in
                NarrativeSessionEntryRow(entry: entry)
            }

            if session.entries.count > previewCount {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "Show less" : "\(session.entries.count - previewCount) more…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)

        Divider()
    }
}

private struct NarrativeSessionEntryRow: View {
    let entry: DreamSession.Entry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.timestamp, format: .dateTime.hour().minute())
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)
                .padding(.top, 3)
            Text(entry.message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal)
    }
}

// MARK: - Dream History

struct DreamHistoryView: View {
    let dreamLog: DreamLog
    let dreamService: DreamService
    let memoryStore: MemoryStore

    var body: some View {
        let sessions = dreamLog.savedSessions()
        Group {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No dreams yet",
                    systemImage: "moon.stars",
                    description: Text("Tap Dream to start.")
                )
            } else {
                List {
                    ForEach(sessions) { session in
                        NavigationLink {
                            DreamSessionView(session: session)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.startedAt, format: .dateTime.weekday().day().month().year())
                                    .font(.subheadline)
                                Text(session.startedAt, format: .dateTime.hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Dream History")
        .navigationBarTitleDisplayMode(.inline)
    }
}
