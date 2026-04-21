import SwiftUI

struct RootView: View {
    @State private var memoryStore = MemoryStore()

    var body: some View {
        TabView {
            CaptureView(memoryStore: memoryStore)
                .tabItem { Label("Capture", systemImage: "camera.fill") }
            MemoryView(memoryStore: memoryStore)
                .tabItem { Label("Memory", systemImage: "brain") }
        }
    }
}
