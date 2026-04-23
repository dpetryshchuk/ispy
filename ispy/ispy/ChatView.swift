import SwiftUI

struct ChatView: View {
    let chatService: ChatService
    let gemmaService: GemmaVisionService
    let memoryStore: MemoryStore
    let wikiStore: WikiStore
    let dreamService: DreamService

    @State private var input = ""
    @State private var showState = false
    @State private var needsDreamCheck = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !gemmaService.state.isReady {
                    modelNotReadyBanner
                }

                // Dream-first gate: show when messages are empty and there's a pending dream
                if chatService.messages.isEmpty && chatService.chatNeedsDream {
                    dreamFirstBanner
                } else {
                    messageList
                    inputBar
                }
            }
            .navigationTitle("Chat")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if chatService.messages.isEmpty {
                        NavigationLink {
                            ChatHistoryView(chatService: chatService)
                        } label: {
                            Image(systemName: "clock")
                        }
                    } else {
                        Button("Clear") { chatService.reset() }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showState = true
                    } label: {
                        Image(systemName: "person.text.rectangle")
                    }
                }
            }
            .sheet(isPresented: $showState) {
                StateFileView(wikiStore: wikiStore)
            }
            .onChange(of: gemmaService.state) { _, _ in
                chatService.setEngine(gemmaService.engine)
            }
            .onAppear {
                chatService.setEngine(gemmaService.engine)
            }
        }
    }

    // MARK: - Dream-first gate

    private var dreamFirstBanner: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "moon.stars")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Dream first")
                .font(.title3).fontWeight(.semibold)
            Text("ispy needs to process its recent experiences before chatting again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                Task { await dreamService.dream(memoryStore: memoryStore) }
            } label: {
                if dreamService.isRunning {
                    HStack(spacing: 8) { ProgressView().scaleEffect(0.8); Text("Dreaming…") }
                } else {
                    Text("Dream Now")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(dreamService.isRunning)

            Button("Skip for now (dev)") {
                chatService.clearChatNeedsDream()
            }
            .font(.caption)
            .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Subviews

    private var modelNotReadyBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("Model not loaded — go to Capture tab to load Gemma 4")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(chatService.messages) { msg in
                        messageRow(msg)
                            .id(msg.id)
                    }
                    if chatService.isThinking && chatService.messages.last?.role.isAssistant != true {
                        thinkingIndicator
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: chatService.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom") }
            }
            .onChange(of: chatService.messages.last?.text) { _, _ in
                proxy.scrollTo("bottom")
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ msg: ChatMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(msg.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

        case .assistant:
            HStack(alignment: .top) {
                if msg.text.isEmpty && msg.isStreaming {
                    thinkingIndicator
                } else {
                    AssistantBubble(text: msg.text, isStreaming: msg.isStreaming, memoryStore: memoryStore)
                    Spacer(minLength: 60)
                }
            }

        case .tool(let name):
            HStack(spacing: 4) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption2)
                Text("\(name): \(msg.text)")
                    .font(.caption2)
                    .lineLimit(2)
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 4) {
            ProgressView().scaleEffect(0.6)
            Text("thinking…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Message ispy…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .focused($focused)
                .onSubmit { sendIfPossible() }

            Button {
                sendIfPossible()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatService.isThinking || !gemmaService.state.isReady)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { Divider() }
    }

    private func sendIfPossible() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chatService.isThinking, gemmaService.state.isReady else { return }
        input = ""
        Task { await chatService.send(text) }
    }
}

// MARK: - Assistant bubble with inline memory cards

struct AssistantBubble: View {
    let text: String
    let isStreaming: Bool
    let memoryStore: MemoryStore

    @State private var selectedMemory: MemoryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments, id: \.id) { seg in
                switch seg.kind {
                case .text(let t):
                    if !t.isEmpty {
                        Text(t.isEmpty ? "…" : t)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(alignment: .bottomTrailing) {
                                if isStreaming && seg.id == segments.last?.id {
                                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).padding(4)
                                }
                            }
                    }
                case .memory(let uuid):
                    if let entry = memoryStore.entries.first(where: { $0.id == uuid }) {
                        Button {
                            selectedMemory = entry
                        } label: {
                            InlineMemoryCard(url: memoryStore.photoURL(for: entry),
                                           timestamp: entry.timestamp)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: $selectedMemory) { entry in
            MemoryDetailView(entry: entry, photoURL: memoryStore.photoURL(for: entry)) {}
        }
    }

    private struct Segment: Identifiable {
        let id = UUID()
        enum Kind { case text(String); case memory(UUID) }
        let kind: Kind
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var seenUUIDs = Set<UUID>()
        guard let re = try? NSRegularExpression(pattern: #"\[\[memory:([0-9A-Fa-f-]{36})\]\]"#) else {
            return [Segment(kind: .text(text))]
        }
        let ns = text as NSString
        var cursor = 0
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            if !before.isEmpty { result.append(Segment(kind: .text(before))) }
            if let uuidRange = Range(m.range(at: 1), in: text),
               let uuid = UUID(uuidString: String(text[uuidRange])),
               seenUUIDs.insert(uuid).inserted {
                result.append(Segment(kind: .memory(uuid)))
            }
            cursor = m.range.location + m.range.length
        }
        let tail = ns.substring(from: cursor)
        if !tail.isEmpty { result.append(Segment(kind: .text(tail))) }
        if result.isEmpty { result.append(Segment(kind: .text(text))) }
        return result
    }
}

struct InlineMemoryCard: View {
    let url: URL
    let timestamp: Date
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let img = image {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Color(.tertiarySystemBackground)
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("Memory")
                    .font(.caption).fontWeight(.semibold)
                Text(timestamp, format: .dateTime.day().month().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
                Text("Tap to view")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundStyle(.quaternary)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: url) {
            let path = url.path
            let loaded = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: path)
            }.value
            image = loaded
        }
    }
}

// MARK: - State file viewer

struct StateFileView: View {
    let wikiStore: WikiStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownContentView(text: wikiStore.readState())
                    .padding()
            }
            .navigationTitle("ispy State")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension ChatMessage.Role {
    var isAssistant: Bool {
        if case .assistant = self { return true }
        return false
    }
}

// MARK: - Chat History

struct ChatHistoryView: View {
    let chatService: ChatService

    var body: some View {
        let sessions = chatService.savedSessions()
        Group {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No past chats",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Past conversations will appear here.")
                )
            } else {
                List(sessions) { session in
                    NavigationLink {
                        ChatSessionView(session: session)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.startedAt, format: .dateTime.weekday(.wide).day().month().year())
                                .font(.subheadline)
                            Text(session.entries.first?.text ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ChatSessionView: View {
    let session: ChatSession

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(session.entries.indices, id: \.self) { i in
                    let entry = session.entries[i]
                    if entry.role == "user" {
                        HStack {
                            Spacer(minLength: 60)
                            Text(entry.text)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.accentColor)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    } else {
                        HStack {
                            Text(entry.text)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            Spacer(minLength: 60)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle(session.startedAt.formatted(.dateTime.weekday().day().month()))
        .navigationBarTitleDisplayMode(.inline)
    }
}
