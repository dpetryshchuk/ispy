import SwiftUI

struct RootView: View {
    let service: LLMService
    @State private var memoryStore = MemoryStore()

    var body: some View {
        TabView {
            CaptureView(service: service, memoryStore: memoryStore)
                .tabItem { Label("Capture", systemImage: "camera.fill") }
            MemoryView(memoryStore: memoryStore)
                .tabItem { Label("Memory", systemImage: "brain") }
        }
    }
}
