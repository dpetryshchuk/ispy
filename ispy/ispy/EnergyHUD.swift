import SwiftUI
import MLX

struct EnergyHUD: View {
    @State private var active: Int = 0
    @State private var cache: Int = 0
    @State private var timer: Timer?

    private var total: Int { active + cache }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "memorychip")
                .font(.caption2)
                .foregroundStyle(energyColor)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.3))

                    let fraction = min(CGFloat(total) / maxMemory, 1.0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(energyColor)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(width: 50, height: 10)

            Text(formatBytes(total))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .onAppear {
            update()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in update() }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private var maxMemory: CGFloat {
        2 * 1024 * 1024 * 1024  // 2GB max
    }

    private var energyColor: Color {
        let fraction = CGFloat(total) / maxMemory
        if fraction > 0.7 {
            return .red
        } else if fraction > 0.4 {
            return .orange
        } else {
            return .green
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1.0 {
            return String(format: "%.1fGB", gb)
        } else {
            let mb = Double(bytes) / (1024 * 1024)
            return String(format: "%.0fMB", mb)
        }
    }

    private func update() {
        active = Memory.activeMemory
        cache = Memory.cacheMemory
    }
}

#Preview {
    EnergyHUD()
}