import SwiftUI

struct RootView: View {
    private let gemmaService: GemmaVisionService
    private let memoryStore: MemoryStore
    private let wikiStore: WikiStore
    private let dreamLog: DreamLog
    private let dreamService: DreamService
    private let chatService: ChatService
    private let promptConfig: PromptConfig

    @State private var selectedTab = 0
    @State private var showDevSettings = false
    @State private var devStageOverride: Int? = nil

    init() {
        let gemma = GemmaVisionService()
        let memory = MemoryStore()
        let wiki = WikiStore()
        let log = DreamLog()
        let prompts = PromptConfig()
        self.gemmaService = gemma
        self.memoryStore = memory
        self.wikiStore = wiki
        self.dreamLog = log
        self.promptConfig = prompts
        self.dreamService = DreamService(wikiStore: wiki, log: log, gemmaService: gemma, promptConfig: prompts)
        self.chatService = ChatService(wikiStore: wiki, memoryStore: memory, promptConfig: prompts)
    }

    var body: some View {
        TabView(selection: $selectedTab) {

            // MARK: ispy home
            NavigationStack {
                IspyView(
                    captureCount: memoryStore.entries.count,
                    wikiPageCount: wikiStore.pageCount(),
                    connectionCount: wikiStore.connectionCount(),
                    isDreaming: dreamService.isRunning,
                    pendingCount: {
                        let cursor = wikiStore.lastDreamed ?? .distantPast
                        return memoryStore.entries.filter { $0.timestamp > cursor }.count
                    }(),
                    lastDreamed: wikiStore.lastDreamed,
                    devStageOverride: devStageOverride
                )
                .navigationTitle("ispy")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showDevSettings = true } label: {
                            Image(systemName: "gearshape")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .tabItem { Label("ispy", systemImage: "moon.stars") }
            .tag(0)

            // MARK: Capture
            CaptureView(gemmaService: gemmaService, memoryStore: memoryStore)
                .tabItem { Label("Capture", systemImage: "camera.fill") }
                .tag(1)

            // MARK: Salients (raw captures)
            MemoryView(memoryStore: memoryStore, lastDreamed: wikiStore.lastDreamed)
                .tabItem { Label("Salients", systemImage: "photo.stack") }
                .tag(2)

            // MARK: Memory (knowledge base + dream + chat)
            MindView(
                wikiStore: wikiStore,
                memoryStore: memoryStore,
                dreamService: dreamService,
                dreamLog: dreamLog,
                chatService: chatService,
                gemmaService: gemmaService
            )
            .tabItem { Label("Memory", systemImage: "sparkles") }
            .tag(3)
        }
        .sheet(isPresented: $showDevSettings) {
            DevSettingsView(
                promptConfig: promptConfig,
                devStageOverride: $devStageOverride
            )
        }
        .task {
            await gemmaService.start()
            dreamService.registerBackgroundTask()
            dreamService.scheduleNextDream()
        }
    }
}
