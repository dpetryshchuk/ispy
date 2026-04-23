import SwiftUI

// MARK: - Stage model

struct EvolutionStage {
    let minCaptures: Int
    let label: String
}

private let stages: [EvolutionStage] = [
    EvolutionStage(minCaptures: 0,    label: "point"),
    EvolutionStage(minCaptures: 5,    label: "line"),
    EvolutionStage(minCaptures: 25,   label: "triangle"),
    EvolutionStage(minCaptures: 100,  label: "diamond"),
    EvolutionStage(minCaptures: 250,  label: "pentagon"),
    EvolutionStage(minCaptures: 500,  label: "hexagon"),
    EvolutionStage(minCaptures: 1000, label: "star"),
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
    let pendingCount: Int       // captures not yet dreamed
    let lastDreamed: Date?

    var devStageOverride: Int? = nil

    @State private var pulse = false

    private var stageIndex: Int {
        devStageOverride ?? evolutionStageIndex(for: captureCount)
    }

    private var nextThreshold: Int {
        let next = stageIndex + 1
        guard next < stages.count else { return -1 }
        return stages[next].minCaptures
    }

    // Pulse speed reflects "hunger" — more pending = faster
    private var pulseSpeed: Double {
        if isDreaming { return 0.9 }
        if pendingCount > 20 { return 1.2 }
        if pendingCount > 5  { return 1.8 }
        return 2.8
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            IspyShapeView(stageIndex: stageIndex, size: 160)
                .scaleEffect(pulse ? 1.04 : 1.0)
                .opacity(isDreaming ? (pulse ? 0.55 : 1.0) : 1.0)
                .animation(
                    (isDreaming || pendingCount > 0)
                        ? .easeInOut(duration: pulseSpeed).repeatForever(autoreverses: true)
                        : .spring(duration: 0.6),
                    value: pulse
                )
                .animation(.spring(duration: 0.6), value: stageIndex)
                .onAppear { pulse = isDreaming || pendingCount > 0 }
                .onChange(of: isDreaming) { _, _ in pulse = isDreaming || pendingCount > 0 }
                .onChange(of: pendingCount) { _, _ in pulse = isDreaming || pendingCount > 0 }
                .padding(.bottom, 14)

            Text(isDreaming ? "dreaming…" : stages[stageIndex].label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            // Pending indicator — small dot row, not overlapping the shape
            if pendingCount > 0 && !isDreaming && devStageOverride == nil {
                HStack(spacing: 4) {
                    ForEach(0..<min(pendingCount, 7), id: \.self) { _ in
                        Circle().fill(Color.orange.opacity(0.7)).frame(width: 4, height: 4)
                    }
                    if pendingCount > 7 {
                        Text("+\(pendingCount - 7)")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange.opacity(0.7))
                    }
                }
                .padding(.top, 6)
            } else if nextThreshold > 0 && devStageOverride == nil {
                Text("\(nextThreshold - captureCount) until next form")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            } else {
                Color.clear.frame(height: 16)
            }

            Spacer()

            HStack(spacing: 40) {
                StatCounter(label: "seen", value: captureCount)
                StatCounter(label: "known", value: wikiPageCount)
                StatCounter(label: "links", value: connectionCount)
            }
            .padding(.bottom, 8)

            if let date = lastDreamed {
                Text("processed \(date, format: .relative(presentation: .named))")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                    .padding(.bottom, 32)
            } else {
                Color.clear.frame(height: 32)
            }
        }
        .padding(.horizontal)
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
                let dot = Path(ellipseIn: CGRect(x: cx - 5, y: cy - 5, width: 10, height: 10))
                ctx.fill(dot, with: .foreground)

            case 1:
                let pts = linePoints(cx: cx, cy: cy, r: r)
                drawEdges(ctx, pts, [(0,1)])
                drawNodes(ctx, pts, r: 4)

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

    private func linePoints(cx: CGFloat, cy: CGFloat, r: CGFloat) -> [CGPoint] {
        [CGPoint(x: cx - r, y: cy), CGPoint(x: cx + r, y: cy)]
    }

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

// MARK: - Stat counter

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
