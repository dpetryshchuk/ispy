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
                    pastSessionsView
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

    private var pastSessionsView: some View {
        let sessions = dreamLog.savedSessions()
        return Group {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No dream yet",
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

struct DreamSessionView: View {
    let session: DreamSession
    @State private var showRaw = false

    var body: some View {
        Group {
            if showRaw {
                rawLogView
            } else {
                narrativeLogView
            }
        }
        .navigationTitle(session.startedAt.formatted(.dateTime.weekday().day().month()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(showRaw ? "Summary" : "Raw") { showRaw.toggle() }
            }
        }
    }

    private var narrativeLogView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(session.entries, id: \.timestamp) { entry in
                    Text("[\(timeString(entry.timestamp))] \(entry.message)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var rawLogView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if session.rawTurns.isEmpty {
                    Text("No raw turns recorded for this session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(session.rawTurns) { turn in
                        RawTurnCard(turn: turn)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

private struct RawTurnCard: View {
    let turn: RawTurn
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(turn.timestamp, format: .dateTime.hour().minute().second())
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(expanded ? "Collapse" : "Expand") { expanded.toggle() }
                    .font(.caption)
            }

            Group {
                sectionLabel("INPUT")
                Text(expanded ? turn.input : String(turn.input.prefix(200)) + (turn.input.count > 200 ? "…" : ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                sectionLabel("OUTPUT")
                Text(expanded ? turn.output : String(turn.output.prefix(200)) + (turn.output.count > 200 ? "…" : ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }
}
