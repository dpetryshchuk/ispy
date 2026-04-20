import SwiftUI

struct ContentView: View {
    @State private var service = LLMService()

    var body: some View {
        switch service.state {
        case .needsDownload:
            VStack(spacing: 24) {
                Text("gemma-3n-E2B (~2 GB)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Download Model") { service.download() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

        case .downloading(let p):
            VStack(spacing: 12) {
                ProgressView(value: p).padding(.horizontal)
                Text("\(Int(p * 100))%")
            }
            .padding()

        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading model...")
            }

        case .ready:
            RootView(service: service)

        case .error(let message):
            VStack(spacing: 16) {
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Retry") { service.start() }
            }
            .padding()
        }
    }
}
