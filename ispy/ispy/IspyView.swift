import SwiftUI

// MARK: - Stage model

struct EvolutionStage {
    let minCaptures: Int
}

private let stages: [EvolutionStage] = [
    EvolutionStage(minCaptures: 0),
    EvolutionStage(minCaptures: 5),
    EvolutionStage(minCaptures: 25),
    EvolutionStage(minCaptures: 100),
    EvolutionStage(minCaptures: 250),
    EvolutionStage(minCaptures: 500),
    EvolutionStage(minCaptures: 1000),
]

func evolutionStageIndex(for captures: Int) -> Int {
    var idx = 0
    for (i, stage) in stages.enumerated() {
        if captures >= stage.minCaptures { idx = i }
    }
    return idx
}

// MARK: - Main view

struct IspyView: View {
    let captureCount: Int
    let wikiPageCount: Int
    let connectionCount: Int
    let isDreaming: Bool
    let pendingCount: Int

    var devStageOverride: Int? = nil

    @State private var breathe = false

    private var stageIndex: Int {
        devStageOverride ?? evolutionStageIndex(for: captureCount)
    }

    private var breatheDuration: Double {
        if isDreaming { return 0.7 }
        if pendingCount > 10 { return 1.0 }
        if pendingCount > 0  { return 1.6 }
        return 2.5
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            IspyShapeView(stageIndex: stageIndex, size: 160)
                .scaleEffect(breathe ? 1.05 : 1.0)
                .opacity(isDreaming && breathe ? 0.6 : 1.0)
                .animation(.spring(duration: 0.6), value: stageIndex)
                .onAppear { startBreathing() }
                .onChange(of: isDreaming) { _, _ in startBreathing() }
                .onChange(of: pendingCount) { _, _ in startBreathing() }
                .onChange(of: stageIndex) { _, _ in startBreathing() }

            Spacer()

            HStack(spacing: 12) {
                StatBox(label: "seen", value: captureCount)
                StatBox(label: "known", value: wikiPageCount)
                StatBox(label: "links", value: connectionCount)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startBreathing() {
        breathe = false
        let duration = breatheDuration
        withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
            breathe = true
        }
    }
}

// MARK: - Shape renderer

struct IspyShapeView: View {
    let stageIndex: Int
    let size: CGFloat

    var body: some View {
        Canvas { ctx, sz in
            let cx = sz.width / 2
            let cy = sz.height / 2
            let r = sz.width / 2 * 0.82

            switch stageIndex {
            case 0:
                // Point — small dot
                let dot = Path(ellipseIn: CGRect(x: cx - 5, y: cy - 5, width: 10, height: 10))
                ctx.fill(dot, with: .foreground)

            case 1:
                // Line stage — slightly larger dot (no literal line)
                let dot = Path(ellipseIn: CGRect(x: cx - 9, y: cy - 9, width: 18, height: 18))
                ctx.fill(dot, with: .foreground)

            case 2:
                let pts = polygonPoints(cx: cx, cy: cy, r: r, n: 3, rotation: -.pi / 2)
                drawEdges(ctx, pts, allEdges(n: 3))
                drawNodes(ctx, pts, r: 4)

            case 3:
                let pts = polygonPoints(cx: cx, cy: cy, r: r, n: 4, rotation: -.pi / 2)
                drawEdges(ctx, pts, allEdges(n: 4))
                drawEdges(ctx, pts, [(0,2),(1,3)], dashed: true, alpha: 0.3)
                drawNodes(ctx, pts, r: 4)

            case 4:
                let pts = polygonPoints(cx: cx, cy: cy, r: r, n: 5, rotation: -.pi / 2)
                drawEdges(ctx, pts, allEdges(n: 5))
                drawEdges(ctx, pts, [(0,2),(0,3),(1,3),(1,4),(2,4)], dashed: true, alpha: 0.25)
                drawNodes(ctx, pts, r: 4)

            case 5:
                let pts = polygonPoints(cx: cx, cy: cy, r: r, n: 6, rotation: 0)
                drawEdges(ctx, pts, allEdges(n: 6))
                drawEdges(ctx, pts, allDiagonals(n: 6), dashed: true, alpha: 0.2)
                drawNodes(ctx, pts, r: 4)

            default:
                let outer = polygonPoints(cx: cx, cy: cy, r: r, n: 6, rotation: -.pi / 6)
                let inner = polygonPoints(cx: cx, cy: cy, r: r * 0.5, n: 6, rotation: 0)
                var all: [CGPoint] = []
                for i in 0..<6 { all.append(outer[i]); all.append(inner[i]) }
                let rim: [(Int,Int)] = (0..<12).map { ($0, ($0+1) % 12) }
                var withCenter = all
                withCenter.append(CGPoint(x: cx, y: cy))
                let spokes: [(Int,Int)] = (0..<6).map { ($0*2, 12) }
                drawEdges(ctx, all, rim)
                drawEdges(ctx, withCenter, spokes, alpha: 0.4)
                drawEdges(ctx, all, allDiagonals(n: 12), dashed: true, alpha: 0.15)
                drawNodes(ctx, outer, r: 4)
                drawNodes(ctx, inner, r: 2.5)
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(Color.primary)
    }

    // MARK: helpers

    private func polygonPoints(cx: CGFloat, cy: CGFloat, r: CGFloat, n: Int, rotation: CGFloat) -> [CGPoint] {
        (0..<n).map { i in
            let angle = rotation + 2 * .pi * CGFloat(i) / CGFloat(n)
            return CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
        }
    }

    private func allEdges(n: Int) -> [(Int,Int)] {
        (0..<n).map { ($0, ($0+1) % n) }
    }

    private func allDiagonals(n: Int) -> [(Int,Int)] {
        var result: [(Int,Int)] = []
        for i in 0..<n {
            for j in (i+2)..<n {
                if !(i == 0 && j == n-1) { result.append((i,j)) }
            }
        }
        return result
    }

    private func drawEdges(_ ctx: GraphicsContext, _ pts: [CGPoint], _ edges: [(Int,Int)],
                           dashed: Bool = false, alpha: CGFloat = 1.0) {
        for (a, b) in edges {
            guard a < pts.count, b < pts.count else { continue }
            var path = Path()
            path.move(to: pts[a])
            path.addLine(to: pts[b])
            var c = ctx
            c.opacity = alpha
            if dashed {
                c.stroke(path, with: .foreground,
                         style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            } else {
                c.stroke(path, with: .foreground,
                         style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
        }
    }

    private func drawNodes(_ ctx: GraphicsContext, _ pts: [CGPoint], r: CGFloat) {
        for pt in pts {
            let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r*2, height: r*2)
            ctx.fill(Path(ellipseIn: rect), with: .foreground)
        }
    }
}

// MARK: - Stat box

struct StatBox: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(spacing: 6) {
            Text("\(value)")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
