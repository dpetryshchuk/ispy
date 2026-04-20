import SwiftUI

struct ContentView: View {
    @State private var service = LLMService()

    var body: some View {
        VStack(spacing: 24) {
            switch service.state {
            case .needsDownload:
                Text("gemma-3n-E4B (~4 GB)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Download Model") {
                    service.download()
                }
                .buttonStyle(.borderedProminent)

            case .downloading(let p):
                ProgressView(value: p)
                    .padding(.horizontal)
                Text("\(Int(p * 100))%")

            case .loading:
                ProgressView()
                Text("Loading model...")

            case .ready(let response):
                Text("Prompt: \"\(LLMService.prompt)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    Text(response)
                        .padding()
                        .textSelection(.enabled)
                }

            case .error(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding()
                Button("Retry") { service.start() }
            }
        }
        .padding()
        .onAppear { service.start() }
    }
}
