import SwiftUI

struct IspyView: View {
    let captureCount: Int
    let wikiPageCount: Int
    let connectionCount: Int
    let isDreaming: Bool
    let onDream: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Circle()
                .fill(.purple.opacity(0.8))
                .frame(width: 120, height: 120)
                .onTapGesture {
                    if !isDreaming { onDream() }
                }

            Text(isDreaming ? "dreaming…" : "tap to dream")
                .font(.caption)
                .foregroundStyle(isDreaming ? .purple : .secondary)

            Spacer()

            HStack(spacing: 32) {
                StatCounter(label: "captures", value: captureCount)
                StatCounter(label: "pages", value: wikiPageCount)
                StatCounter(label: "links", value: connectionCount)
            }
            .padding(.bottom, 40)
        }
        .padding()
    }
}

struct StatCounter: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 22, weight: .light, design: .rounded))
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
