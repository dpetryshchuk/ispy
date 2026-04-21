import SwiftUI

struct RootView: View {
    private let gemmaService: GemmaVisionService
    private let memoryStore: MemoryStore
    private let wikiStore: WikiStore
    private let dreamLog: DreamLog
    private let dreamService: DreamService

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
        TabView {
            IspyView(
                captureCount: memoryStore.entries.count,
                wikiPageCount: wikiStore.pageCount(),
                connectionCount: wikiStore.connectionCount(),
                isDreaming: dreamService.isRunning,
                onDream: { Task { await dreamService.dream(memoryStore: memoryStore) } }
            )
            .tabItem { Label("Ispy", systemImage: "moon.stars") }

            CaptureView(gemmaService: gemmaService, memoryStore: memoryStore)
                .tabItem { Label("Capture", systemImage: "camera.fill") }

            MemoryView(memoryStore: memoryStore)
                .tabItem { Label("Memory", systemImage: "brain") }

            WikiView(wikiStore: wikiStore)
                .tabItem { Label("Wiki", systemImage: "folder") }

            DreamView(dreamService: dreamService, dreamLog: dreamLog, memoryStore: memoryStore)
                .tabItem { Label("Dream", systemImage: "sparkles") }
        }
        .task {
            await gemmaService.start()
            dreamService.registerBackgroundTask()
            dreamService.scheduleNextDream()
        }
    }
}
