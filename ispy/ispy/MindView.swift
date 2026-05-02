import SwiftUI

struct MindView: View {
    let wikiStore: WikiStore
    let memoryStore: MemoryStore
    let dreamService: DreamService
    let dreamLog: DreamLog

    @State private var selectedPage: WikiPage?
    @State private var showGraph = false
    @State private var showKnowledgeMap = false
    @State private var showDreamLog = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showGraph {
                    WikiGraphView(wikiStore: wikiStore) { selectedPage = $0 }
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    filesAndDreamView
                }
            }
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) { showGraph.toggle() }
                    } label: {
                        Image(systemName: showGraph ? "list.bullet" : "map")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if dreamService.isRunning {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Menu {
                            Button("Dream") {
                                showDreamLog = true
                                Task { await dreamService.dream(memoryStore: memoryStore) }
                            }
                            Button("Reflect only") {
                                showDreamLog = true
                                Task { await dreamService.reflect() }
                            }
                            Button("Consolidate only") {
                                showDreamLog = true
                                Task { await dreamService.consolidate() }
                            }
                        } label: {
                            Text("Dream")
                        }
                    }
                }
            }
            .sheet(item: $selectedPage) { page in
                WikiPageView(page: page, wikiStore: wikiStore, memoryStore: memoryStore) {
                    selectedPage = $0
                }
            }
            .sheet(isPresented: $showKnowledgeMap) {
                KnowledgeMapView(wikiStore: wikiStore)
            }
            .sheet(isPresented: $showDreamLog) {
                DreamView(dreamService: dreamService, dreamLog: dreamLog, memoryStore: memoryStore)
            }
        }
    }

    // MARK: - Files + recent dream

    private var filesAndDreamView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Dream status / active dream
                if dreamService.isRunning {
                    activeDreamBanner
                } else if let error = dreamService.lastError {
                    Text(error)
                        .font(.caption).foregroundStyle(.red)
                        .padding(.horizontal).padding(.top, 8)
                }

                // Wiki file browser
                wikiFilesSection

                // Recent dream narrative
                if !dreamLog.savedSessions().isEmpty {
                    recentDreamSection
                }
            }
        }
    }

    private var activeDreamBanner: some View {
        Button { showDreamLog = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.75)
                    Text("Dreaming now")
                        .font(.caption).fontWeight(.semibold).foregroundStyle(.purple)
                    Spacer()
                    Text("View log →")
                        .font(.caption2).foregroundStyle(.purple.opacity(0.7))
                }
                if let phase = dreamLog.phases.last {
                    Text(phase.label)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    if let step = phase.runningStep {
                        Text("  → \(step.label)")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
        }
        .buttonStyle(.plain)
    }

    private var wikiFilesSection: some View {
        let pages = wikiStore.allPages().sorted { $0.path < $1.path }
        let grouped = Dictionary(grouping: pages) { $0.folder }
        let folders = grouped.keys.sorted()

        return Group {
            if pages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "brain")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("Nothing stored yet")
                        .font(.subheadline).foregroundStyle(.tertiary)
                    Text("Tap Dream to start building memory")
                        .font(.caption).foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else {
                // Pinned knowledge map entry
                Button { showKnowledgeMap = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "map.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue.opacity(0.8))
                        Text("Knowledge Map")
                            .foregroundStyle(.primary)
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(.quaternary)
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal)
                }
                Divider().padding(.leading)

                ForEach(folders, id: \.self) { folder in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.caption2)
                                .foregroundStyle(folderColor(folder))
                            Text(folder.capitalized)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(folderColor(folder))
                        }
                        .padding(.horizontal)
                        .padding(.top, 16)
                        .padding(.bottom, 4)

                        ForEach(grouped[folder] ?? []) { page in
                            Button {
                                selectedPage = page
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(folderColor(folder).opacity(0.6))
                                        .frame(width: 6, height: 6)
                                    Text(page.title)
                                        .foregroundStyle(.primary)
                                        .font(.subheadline)
                                    Spacer()
                                    if !page.links.isEmpty {
                                        Text("\(page.links.count)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.caption2).foregroundStyle(.quaternary)
                                }
                                .padding(.vertical, 9)
                                .padding(.horizontal)
                            }
                            Divider().padding(.leading)
                        }
                    }
                }
            }
        }
    }

    private var recentDreamSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent processing")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                NavigationLink {
                    DreamHistoryView(dreamLog: dreamLog, dreamService: dreamService, memoryStore: memoryStore)
                } label: {
                    Text("All sessions")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal)
            .padding(.top, 20)

            let session = dreamLog.savedSessions().first
            if let session {
                DreamNarrativeCard(session: session)
            }
        }
        .padding(.bottom, 40)
    }
}

// MARK: - Narrative Entry Row (shared)

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

    private let previewCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.startedAt, format: .dateTime.weekday(.wide).month().day())
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            let displayEntries = expanded ? session.entries : Array(session.entries.prefix(previewCount))

            ForEach(displayEntries, id: \.timestamp) { entry in
                NarrativeEntryRow(
                    timestamp: entry.timestamp.formatted(.dateTime.hour().minute()),
                    message: entry.message
                )
            }

            if session.entries.count > previewCount {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "Show less" : "\(session.entries.count - previewCount) more…")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)

        Divider()
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
                            SessionDetailView(session: session)
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

// MARK: - Knowledge Map

struct KnowledgeMapView: View {
    let wikiStore: WikiStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownContentView(text: wikiStore.listWiki())
                    .padding()
            }
            .navigationTitle("Knowledge Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
