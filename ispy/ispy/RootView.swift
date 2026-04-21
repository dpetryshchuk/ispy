import SwiftUI

struct RootView: View {
    @State private var gemmaService = GemmaVisionService()
    @State private var memoryStore = MemoryStore()

    var body: some View {
        TabView {
            CaptureView(gemmaService: gemmaService, memoryStore: memoryStore)
                .tabItem { Label("Capture", systemImage: "camera.fill") }
            MemoryView(memoryStore: memoryStore)
                .tabItem { Label("Memory", systemImage: "brain") }
        }
        .task { await gemmaService.start() }
    }
}
