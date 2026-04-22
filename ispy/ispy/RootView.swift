import SwiftUI

struct RootView: View {
    private let gemmaService: GemmaVisionService
    private let memoryStore: MemoryStore
    private let wikiStore: WikiStore
    private let dreamLog: DreamLog
    private let dreamService: DreamService

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
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            IspyView(
                captureCount: memoryStore.entries.count,
                wikiPageCount: wikiStore.pageCount(),
                connectionCount: wikiStore.connectionCount(),
                isDreaming: dreamService.isRunning,
                onDream: {
                    selectedTab = 4
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

            WikiView(wikiStore: wikiStore)
                .tabItem { Label("Wiki", systemImage: "folder") }
                .tag(3)

            DreamView(dreamService: dreamService, dreamLog: dreamLog, memoryStore: memoryStore)
                .tabItem { Label("Dream", systemImage: "sparkles") }
                .tag(4)
        }
        .task {
            await gemmaService.start()
            dreamService.registerBackgroundTask()
            dreamService.scheduleNextDream()
        }
    }
}
