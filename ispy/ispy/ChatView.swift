import SwiftUI

struct ChatView: View {
    let chatService: ChatService
    let gemmaService: GemmaVisionService

    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !gemmaService.state.isReady {
                    modelNotReadyBanner
                }

                messageList

                inputBar
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
            }
            .onChange(of: gemmaService.state) { _, _ in
                chatService.setEngine(gemmaService.engine)
            }
            .onAppear {
                chatService.setEngine(gemmaService.engine)
            }
        }
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
                    Text(msg.text.isEmpty ? "…" : msg.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(alignment: .bottomTrailing) {
                            if msg.isStreaming {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 6, height: 6)
                                    .padding(4)
                            }
                        }
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
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func sendIfPossible() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chatService.isThinking, gemmaService.state.isReady else { return }
        input = ""
        Task { await chatService.send(text) }
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
