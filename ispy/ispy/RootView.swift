import SwiftUI

struct RootView: View {
    private let gemmaService: GemmaVisionService
    private let memoryStore: MemoryStore
    private let wikiStore: WikiStore
    private let dreamLog: DreamLog
    private let dreamService: DreamService
    private let chatService: ChatService

    @State private var selectedTab = 0

    init() {
        let gemma = GemmaVisionService()
        let memory = MemoryStore()
        let wiki = WikiStore()
        let log = DreamLog()
        self.gemmaService = gemma
        self.memoryStore = memory
        self.wikiStore = wiki
        self.dreamLog = log
        self.dreamService = DreamService(wikiStore: wiki, log: log, gemmaService: gemma)
        self.chatService = ChatService(wikiStore: wiki, memoryStore: memory)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            IspyView(
                captureCount: memoryStore.entries.count,
                wikiPageCount: wikiStore.pageCount(),
                connectionCount: wikiStore.connectionCount(),
                isDreaming: dreamService.isRunning,
                onDream: {
                    selectedTab = 5
                    Task { await dreamService.dream(memoryStore: memoryStore) }
                }
            )
            .tabItem { Label("Ispy", systemImage: "moon.stars") }
            .tag(0)

            CaptureView(gemmaService: gemmaService, memoryStore: memoryStore)
                .tabItem { Label("Capture", systemImage: "camera.fill") }
                .tag(1)

            MemoryView(memoryStore: memoryStore, lastDreamed: wikiStore.lastDreamed)
                .tabItem { Label("Memory", systemImage: "brain") }
                .tag(2)

            WikiView(wikiStore: wikiStore, memoryStore: memoryStore)
                .tabItem { Label("Wiki", systemImage: "folder") }
                .tag(3)

            ChatView(chatService: chatService, gemmaService: gemmaService)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(4)

            DreamView(dreamService: dreamService, dreamLog: dreamLog, memoryStore: memoryStore)
                .tabItem { Label("Dream", systemImage: "sparkles") }
                .tag(5)
        }
        .task {
            await gemmaService.start()
            dreamService.registerBackgroundTask()
            dreamService.scheduleNextDream()
        }
    }
}
