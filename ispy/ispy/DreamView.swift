import SwiftUI

// MARK: - Root

struct DreamView: View {
    let dreamService: DreamService
    let dreamLog: DreamLog
    let memoryStore: MemoryStore

    @State private var selectedStep: DreamStep? = nil
    @State private var showHistory = false

    var body: some View {
        NavigationStack {
            Group {
                if dreamLog.phases.isEmpty {
                    historyOrEmpty
                } else {
                    liveSessionView
                }
            }
            .navigationTitle("Dream Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if dreamService.isRunning {
                        Button("Stop") { dreamService.cancel() }
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    } else if !dreamLog.phases.isEmpty {
                        Button("History") { showHistory = true }
                            .font(.subheadline)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await dreamService.dream(memoryStore: memoryStore) }
                    } label: {
                        if dreamService.isRunning {
                            HStack(spacing: 6) { ProgressView().scaleEffect(0.8); Text("Dreaming") }
                        } else {
                            Text("Dream")
                        }
                    }
                    .disabled(dreamService.isRunning)
                }
            }
            .sheet(item: $selectedStep) { step in
                StepDetailView(step: step)
            }
            .sheet(isPresented: $showHistory) {
                DreamHistorySheet(dreamLog: dreamLog)
            }
        }
    }

    // MARK: - Live session

    private var liveSessionView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                sessionHeader
                ForEach(dreamLog.phases) { phase in
                    PhaseCard(phase: phase) { step in selectedStep = step }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var sessionHeader: some View {
        HStack(spacing: 10) {
            if dreamService.isRunning {
                Circle().fill(Color.purple).frame(width: 8, height: 8)
                    .overlay(
                        Circle().stroke(Color.purple.opacity(0.3), lineWidth: 4)
                            .scaleEffect(1.6).opacity(0.8)
                    )
                Text("Dreaming")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.purple)
                Spacer()
                if let start = dreamLog.sessionStartedAt {
                    Text(start, style: .timer)
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
                Text("Complete")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                if let start = dreamLog.sessionStartedAt,
                   let last = dreamLog.phases.last?.endedAt {
                    Text(formatDuration(last.timeIntervalSince(start)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    // MARK: - Empty / history

    private var historyOrEmpty: some View {
        let sessions = dreamLog.savedSessions()
        return Group {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No dreams yet",
                    systemImage: "moon.stars",
                    description: Text("Tap Dream to start processing captures.")
                )
            } else {
                SessionListView(sessions: sessions)
            }
        }
    }
}

// MARK: - Phase card

private struct PhaseCard: View {
    let phase: DreamPhase
    let onStepTap: (DreamStep) -> Void
    @State private var expanded: Bool

    init(phase: DreamPhase, onStepTap: @escaping (DreamStep) -> Void) {
        self.phase = phase
        self.onStepTap = onStepTap
        _expanded = State(initialValue: phase.isRunning || phase.succeeded == false)
    }

    var body: some View {
        VStack(spacing: 0) {
            phaseHeader
            if expanded && !phase.steps.isEmpty {
                Divider()
                ForEach(phase.steps.indices, id: \.self) { i in
                    StepRow(step: phase.steps[i], onTap: { onStepTap(phase.steps[i]) })
                    if i < phase.steps.count - 1 { Divider().padding(.leading, 44) }
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: phase.isRunning) { _, running in
            if running { withAnimation(.easeIn(duration: 0.2)) { expanded = true } }
        }
    }

    private var phaseHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                PhaseStatusIcon(phase: phase)
                VStack(alignment: .leading, spacing: 1) {
                    Text(phase.label)
                        .font(.subheadline).fontWeight(.medium)
                        .foregroundStyle(.primary)
                    if phase.isRunning, let running = phase.runningStep {
                        Text(running.label)
                            .font(.caption2).foregroundStyle(.purple)
                            .lineLimit(1)
                    } else if let err = phase.steps.first(where: { $0.succeeded == false })?.errorMessage {
                        Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1)
                    }
                }
                Spacer()
                if phase.totalTools > 0 {
                    Text("\(phase.totalTools) calls")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if phase.isRunning {
                    Text(phase.startedAt, style: .timer)
                        .font(.caption2.monospacedDigit()).foregroundStyle(.purple.opacity(0.8))
                } else if let d = phase.duration {
                    Text(formatDuration(d))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2).foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step row

private struct StepRow: View {
    let step: DreamStep
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                StepStatusIcon(step: step)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.label)
                        .font(.subheadline).foregroundStyle(.primary)
                    if let preview = step.lastEventPreview {
                        Text(preview)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    if step.toolCount > 0 {
                        Label("\(step.toolCount)", systemImage: "wrench.and.screwdriver")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .labelStyle(.titleAndIcon)
                    }
                    if step.isRunning {
                        ProgressView().scaleEffect(0.55)
                    } else if let d = step.duration {
                        Text(formatDuration(d))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.quaternary)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step detail sheet

struct StepDetailView: View {
    let step: DreamStep
    @State private var showRaw = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if showRaw {
                    rawTurnsView
                } else {
                    eventsView
                }
            }
            .navigationTitle(step.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !step.rawTurns.isEmpty {
                        Button(showRaw ? "Events" : "Raw LLM") {
                            withAnimation(.easeInOut(duration: 0.2)) { showRaw.toggle() }
                        }
                    }
                }
            }
        }
    }

    private var eventsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                stepSummaryBanner
                ForEach(step.events) { event in
                    EventRow(event: event)
                }
                if step.events.isEmpty {
                    Text("No events recorded")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding()
                }
            }
            .padding()
        }
    }

    private var stepSummaryBanner: some View {
        HStack(spacing: 12) {
            StepStatusIcon(step: step)
            VStack(alignment: .leading, spacing: 2) {
                if let d = step.duration {
                    Text("\(formatDuration(d)) · \(step.toolCount) tool calls · \(step.llmCount) LLM turns")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Running…").font(.caption).foregroundStyle(.purple)
                }
                if let err = step.errorMessage {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var rawTurnsView: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(step.rawTurns) { turn in
                    RawTurnCard(turn: turn)
                }
            }
            .padding()
        }
    }
}

// MARK: - Event row

private struct EventRow: View {
    let event: StepEvent
    @State private var expanded = false

    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
            HStack(alignment: .top, spacing: 10) {
                eventIcon
                    .frame(width: 18, alignment: .center)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(eventTitle)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(eventTitleColor)
                    Text(expanded ? eventFullBody : eventShortBody)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(expanded ? nil : 3)
                }
                Spacer(minLength: 0)
                Text(event.timestamp, format: .dateTime.hour().minute().second())
                    .font(.system(size: 9)).foregroundStyle(.quaternary)
                    .padding(.top, 2)
            }
            .padding(10)
            .background(eventBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var eventIcon: some View {
        Group {
            switch event.kind {
            case .tool:  Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(.blue).font(.system(size: 10))
            case .llm:   Image(systemName: "waveform").foregroundStyle(.purple).font(.system(size: 10))
            case .info:  Image(systemName: "info.circle.fill").foregroundStyle(.secondary).font(.system(size: 10))
            case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 10))
            }
        }
    }

    private var eventTitle: String {
        switch event.kind {
        case .tool(let n, _, _): return "→ \(n)"
        case .llm:               return "LLM"
        case .info:              return "info"
        case .error:             return "error"
        }
    }

    private var eventTitleColor: Color {
        switch event.kind {
        case .tool:  return .blue
        case .llm:   return .purple
        case .info:  return .secondary
        case .error: return .red
        }
    }

    private var eventShortBody: String {
        switch event.kind {
        case .tool(_, let args, let preview): return "\(args.prefix(60))\n→ \(preview)"
        case .llm(let p):                    return p
        case .info(let m):                   return m
        case .error(let m):                  return m
        }
    }

    private var eventFullBody: String {
        switch event.kind {
        case .tool(_, let args, let preview): return "\(args)\n→ \(preview)"
        case .llm(let p):                    return p
        case .info(let m):                   return m
        case .error(let m):                  return m
        }
    }

    private var eventBackground: Color {
        switch event.kind {
        case .tool:  return Color.blue.opacity(0.06)
        case .llm:   return Color.purple.opacity(0.06)
        case .info:  return Color(.tertiarySystemBackground)
        case .error: return Color.red.opacity(0.08)
        }
    }
}

// MARK: - History

private struct DreamHistorySheet: View {
    let dreamLog: DreamLog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SessionListView(sessions: dreamLog.savedSessions())
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

private struct SessionListView: View {
    let sessions: [DreamSession]

    var body: some View {
        List(sessions) { session in
            NavigationLink {
                SessionDetailView(session: session)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.startedAt, format: .dateTime.weekday(.wide).day().month().year())
                        .font(.subheadline)
                    HStack(spacing: 8) {
                        Text(session.startedAt, format: .dateTime.hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                        let total = session.phases.reduce(0) { $0 + $1.totalTools }
                        if total > 0 {
                            Text("· \(total) tool calls")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        let failed = session.phases.filter { $0.succeeded == false }.count
                        if failed > 0 {
                            Text("· \(failed) errors").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

struct SessionDetailView: View {
    let session: DreamSession
    @State private var selectedStep: DreamStep? = nil

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(session.phases) { phase in
                    PhaseCard(phase: phase) { step in selectedStep = step }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .navigationTitle(session.startedAt.formatted(.dateTime.weekday().day().month()))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedStep) { step in
            StepDetailView(step: step)
        }
    }
}

// MARK: - Raw turn card

private struct RawTurnCard: View {
    let turn: RawTurn
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(turn.timestamp, format: .dateTime.hour().minute().second())
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button(expanded ? "Collapse" : "Expand") {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }.font(.caption)
            }
            sectionLabel("INPUT")
            Text(expanded ? turn.input : String(turn.input.prefix(300)) + (turn.input.count > 300 ? "…" : ""))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            sectionLabel("OUTPUT")
            Text(expanded ? turn.output : String(turn.output.prefix(400)) + (turn.output.count > 400 ? "…" : ""))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary).padding(.top, 2)
    }
}

// MARK: - Status icons

private struct PhaseStatusIcon: View {
    let phase: DreamPhase
    var body: some View {
        Group {
            if phase.isRunning {
                ProgressView().scaleEffect(0.65).tint(.purple)
            } else if phase.succeeded == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        .frame(width: 18, height: 18)
    }
}

private struct StepStatusIcon: View {
    let step: DreamStep
    var body: some View {
        Group {
            if step.isRunning {
                ProgressView().scaleEffect(0.55).tint(.purple)
            } else if step.succeeded == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            } else {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
            }
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - Helpers

private func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t)
    if s < 60 { return "\(s)s" }
    return "\(s/60)m\(s%60)s"
}
