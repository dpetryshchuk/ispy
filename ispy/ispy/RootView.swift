import SwiftUI

struct RootView: View {
    @State private var llmService = LLMService()
    @State private var memoryStore = MemoryStore()

    var body: some View {
        TabView {
            CaptureView(llmService: llmService, memoryStore: memoryStore)
                .tabItem { Label("Capture", systemImage: "camera.fill") }
            MemoryView(memoryStore: memoryStore)
                .tabItem { Label("Memory", systemImage: "brain") }
        }
        .onAppear { llmService.start() }
    }
}
