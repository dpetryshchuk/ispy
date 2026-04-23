import SwiftUI

// MARK: - Stage model

struct EvolutionStage {
    let minCaptures: Int
}

private let stages: [EvolutionStage] = [
    EvolutionStage(minCaptures: 0),    // dot
    EvolutionStage(minCaptures: 10),   // line
    EvolutionStage(minCaptures: 25),   // triangle
    EvolutionStage(minCaptures: 50),   // diamond
    EvolutionStage(minCaptures: 100),  // pentagon
    EvolutionStage(minCaptures: 200),  // hexagon
    EvolutionStage(minCaptures: 500),  // star
]

private let stageNames = ["dot", "line", "triangle", "diamond", "pentagon", "hexagon", "star"]

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

    private var milestoneGlow: (color: Color, radius: CGFloat)? {
        guard captureCount >= 10 else { return nil }
        let milestone = captureCount / 10
        let hue = Double(milestone % 12) / 12.0
        let withinWindow = Double(captureCount % 10) / 10.0
        let intensity = 0.25 + withinWindow * 0.35
        let radius: CGFloat = 10 + CGFloat(withinWindow) * 10
        return (Color(hue: hue, saturation: 0.7, brightness: 1.0).opacity(intensity), radius)
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

            let glow = milestoneGlow
            IspyShapeView(stageIndex: stageIndex, size: 160,
                          glowColor: glow?.color ?? .clear,
                          glowRadius: glow?.radius ?? 0)
                .scaleEffect(breathe ? 1.05 : 1.0)
                .opacity(isDreaming && breathe ? 0.6 : 1.0)
                .animation(.spring(duration: 0.6), value: stageIndex)
                .onAppear { startBreathing() }
                .onChange(of: isDreaming) { _, _ in startBreathing() }
                .onChange(of: pendingCount) { _, _ in startBreathing() }
                .onChange(of: stageIndex) { _, _ in startBreathing() }

            Spacer()

            if let prog = progressText {
                Text(prog)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 10)
            }

            HStack(spacing: 12) {
                StatBox(label: "experiences", value: captureCount)
                StatBox(label: "known", value: wikiPageCount)
                StatBox(label: "links", value: connectionCount)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressText: String? {
        guard devStageOverride == nil else { return nil }
        let nextIdx = stageIndex + 1
        guard nextIdx < stages.count else { return nil }
        let name = nextIdx < stageNames.count ? stageNames[nextIdx] : "next"
        return "\(captureCount) / \(stages[nextIdx].minCaptures) to \(name)"
    }

    private func startBreathing() {
        breathe = false
        let duration = breatheDuration
        withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
            breathe = true
        }
    }
}

// MARK: - Animated shape (TimelineView for per-vertex independent motion)

struct IspyShapeView: View {
    let stageIndex: Int
    let size: CGFloat
    var isAnalyzing: Bool = false
    var glowColor: Color = .clear
    var glowRadius: CGFloat = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { tl in
            let rawT = tl.date.timeIntervalSinceReferenceDate
            let t = isAnalyzing ? rawT * 3.5 : rawT  // fast when analyzing
            Canvas { ctx, sz in
                let cx = sz.width / 2
                let cy = sz.height / 2
                let r = sz.width / 2 * 0.82
                drawStage(ctx: ctx, cx: cx, cy: cy, r: r, t: t)
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(Color.primary)
        .shadow(color: glowColor, radius: glowRadius, x: 0, y: 0)
    }

    private func drawStage(ctx: GraphicsContext, cx: CGFloat, cy: CGFloat, r: CGFloat, t: Double) {
        switch stageIndex {
        case 0:
            // Dot: pulses in size
            let s = CGFloat(6 + 4 * sin(t * 1.3))
            ctx.fill(Path(ellipseIn: CGRect(x: cx - s, y: cy - s, width: s*2, height: s*2)), with: .foreground)

        case 1:
            // Line: each endpoint oscillates its distance from center independently
            let r1 = r * CGFloat(0.55 + 0.45 * sin(t * 0.9))
            let r2 = r * CGFloat(0.55 + 0.45 * sin(t * 1.1 + 1.4))
            let ptA = CGPoint(x: cx - r1, y: cy)
            let ptB = CGPoint(x: cx + r2, y: cy)
            var path = Path()
            path.move(to: ptA); path.addLine(to: ptB)
            ctx.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            for pt in [ptA, ptB] {
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x-4, y: pt.y-4, width: 8, height: 8)), with: .foreground)
            }

        case 2:
            // Triangle: each vertex oscillates its radius independently
            let rs = [
                r * CGFloat(0.72 + 0.28 * sin(t * 0.8)),
                r * CGFloat(0.72 + 0.28 * sin(t * 1.1 + 2.1)),
                r * CGFloat(0.72 + 0.28 * sin(t * 0.95 + 4.2)),
            ]
            let pts = (0..<3).map { i -> CGPoint in
                let angle = -.pi/2 + 2 * .pi * CGFloat(i) / 3
                return CGPoint(x: cx + rs[i] * cos(angle), y: cy + rs[i] * sin(angle))
            }
            drawEdges(ctx, pts, [(0,1),(1,2),(2,0)])
            drawNodes(ctx, pts, r: 4)

        case 3:
            let rs: [CGFloat] = (0..<4).map { i in
                let s = sin(t * (0.7 + Double(i) * 0.15) + Double(i) * 1.5)
                return r * CGFloat(0.78 + 0.22 * s)
            }
            let pts = (0..<4).map { i -> CGPoint in
                let angle = -.pi/2 + 2 * .pi * CGFloat(i) / 4
                return CGPoint(x: cx + rs[i] * cos(angle), y: cy + rs[i] * sin(angle))
            }
            drawEdges(ctx, pts, [(0,1),(1,2),(2,3),(3,0)])
            drawEdges(ctx, pts, [(0,2),(1,3)], dashed: true, alpha: 0.3)
            drawNodes(ctx, pts, r: 4)

        case 4:
            let rs: [CGFloat] = (0..<5).map { i in
                let s = sin(t * (0.7 + Double(i) * 0.12) + Double(i) * 1.3)
                return r * CGFloat(0.78 + 0.22 * s)
            }
            let pts = (0..<5).map { i -> CGPoint in
                let angle = -.pi/2 + 2 * .pi * CGFloat(i) / 5
                return CGPoint(x: cx + rs[i] * cos(angle), y: cy + rs[i] * sin(angle))
            }
            drawEdges(ctx, pts, [(0,1),(1,2),(2,3),(3,4),(4,0)])
            drawEdges(ctx, pts, [(0,2),(0,3),(1,3),(1,4),(2,4)], dashed: true, alpha: 0.25)
            drawNodes(ctx, pts, r: 4)

        case 5:
            let pts = polygonPoints(cx: cx, cy: cy, r: r, n: 6, rotation: 0)
            drawEdges(ctx, pts, [(0,1),(1,2),(2,3),(3,4),(4,5),(5,0)])
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

    // MARK: - Helpers

    private func polygonPoints(cx: CGFloat, cy: CGFloat, r: CGFloat, n: Int, rotation: CGFloat) -> [CGPoint] {
        (0..<n).map { i in
            let angle = rotation + 2 * .pi * CGFloat(i) / CGFloat(n)
            return CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
        }
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
            path.move(to: pts[a]); path.addLine(to: pts[b])
            var c = ctx; c.opacity = alpha
            if dashed {
                c.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            } else {
                c.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
        }
    }

    private func drawNodes(_ ctx: GraphicsContext, _ pts: [CGPoint], r: CGFloat) {
        for pt in pts {
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x-r, y: pt.y-r, width: r*2, height: r*2)), with: .foreground)
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
