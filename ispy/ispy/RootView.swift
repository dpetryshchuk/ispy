import SwiftUI

struct RootView: View {
    private let gemmaService: GemmaVisionService
    private let lfmService: LFMVisionService
    private let memoryStore: MemoryStore
    private let wikiStore: WikiStore
    private let dreamLog: DreamLog
    private let dreamService: DreamService
    private let chatService: ChatService
    private let promptConfig: PromptConfig

    @State private var selectedTab = 0
    @State private var devStageOverride: Int? = nil

    init() {
        let gemma = GemmaVisionService()
        let lfm = LFMVisionService()
        let memory = MemoryStore()
        let wiki = WikiStore()
        let log = DreamLog()
        let prompts = PromptConfig()
        self.gemmaService = gemma
        self.lfmService = lfm
        self.memoryStore = memory
        self.wikiStore = wiki
        self.dreamLog = log
        self.promptConfig = prompts
        self.dreamService = DreamService(wikiStore: wiki, log: log, gemmaService: gemma, promptConfig: prompts)
        self.chatService = ChatService(wikiStore: wiki, memoryStore: memory, promptConfig: prompts)
    }

    var body: some View {
        TabView(selection: $selectedTab) {

            // MARK: ispy chat (home)
            ChatView(
                chatService: chatService,
                gemmaService: gemmaService,
                memoryStore: memoryStore,
                wikiStore: wikiStore,
                dreamService: dreamService,
                promptConfig: promptConfig,
                devStageOverride: $devStageOverride
            )
            .tabItem { Label("ispy", systemImage: "moon.stars") }
            .tag(0)

            // MARK: Capture
            CaptureView(lfmService: lfmService, memoryStore: memoryStore, isDreaming: dreamService.isRunning)
                .tabItem { Label("Capture", systemImage: "camera.fill") }
                .tag(1)

            // MARK: Experiences (raw captures)
            MemoryView(memoryStore: memoryStore, lastDreamed: wikiStore.lastDreamed)
                .tabItem { Label("Experiences", systemImage: "photo.stack") }
                .tag(2)

            // MARK: Memory (knowledge base + dream)
            MindView(
                wikiStore: wikiStore,
                memoryStore: memoryStore,
                dreamService: dreamService,
                dreamLog: dreamLog
            )
            .tabItem { Label("Memory", systemImage: "sparkles") }
            .tag(3)

            // MARK: ispy creature (tamagotchi)
            IspyView(
                captureCount: memoryStore.entries.count,
                wikiPageCount: wikiStore.allPages().count,
                connectionCount: wikiStore.connectionCount(),
                isDreaming: dreamService.isRunning,
                pendingCount: memoryStore.entries.filter { $0.dreamDescription == nil }.count,
                devStageOverride: devStageOverride
            )
.tabItem { Label("creature", systemImage: "sparkle") }
                .tag(4)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EnergyHUD()
            }
        }
        .task {
            dreamService.registerBackgroundTask()
            dreamService.scheduleNextDream()
        }
    }
}
