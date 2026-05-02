import SwiftUI
import Combine
import UIKit

// Consistent color per folder name, hash-based so new folders get a stable color
func folderColor(_ folder: String) -> Color {
    let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .green, .indigo, .red, .cyan]
    return palette[abs(folder.hashValue) % palette.count]
}

struct WikiView: View {
    let wikiStore: WikiStore
    let memoryStore: MemoryStore
    @State private var selectedPage: WikiPage?
    @State private var showGraph = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $showGraph) {
                    Text("Pages").tag(false)
                    Text("Map").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                if showGraph {
                    WikiGraphView(wikiStore: wikiStore) { selectedPage = $0 }
                } else {
                    WikiFilesView(wikiStore: wikiStore) { selectedPage = $0 }
                }
            }
            .navigationTitle("Memory")
            .sheet(item: $selectedPage) { page in
                WikiPageView(page: page, wikiStore: wikiStore, memoryStore: memoryStore) { selectedPage = $0 }
            }
        }
    }
}

// MARK: - Files (sorted by folder, color-coded)

struct WikiFilesView: View {
    let wikiStore: WikiStore
    let onSelect: (WikiPage) -> Void

    var body: some View {
        let pages = wikiStore.allPages().sorted { $0.path < $1.path }
        let grouped = Dictionary(grouping: pages) { $0.folder }
        let folders = grouped.keys.sorted()

        if pages.isEmpty {
            ContentUnavailableView("No pages yet", systemImage: "folder",
                                   description: Text("Dream to build the wiki."))
        } else {
            List {
                ForEach(folders, id: \.self) { folder in
                    Section {
                        ForEach(grouped[folder] ?? []) { page in
                            Button { onSelect(page) } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(folderColor(folder))
                                        .frame(width: 8, height: 8)
                                    Text(page.title)
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                    } header: {
                        Label(folder.capitalized, systemImage: "folder.fill")
                            .foregroundStyle(folderColor(folder))
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

// MARK: - Graph (force-directed)

struct WikiGraphView: View {
    let wikiStore: WikiStore
    let onSelect: (WikiPage) -> Void

    var body: some View {
        let pages = wikiStore.allPages()
        if pages.isEmpty {
            ContentUnavailableView("No pages yet", systemImage: "map",
                                   description: Text("Dream to build the wiki."))
        } else {
            ForceGraph(pages: pages, onSelect: onSelect)
        }
    }
}

// MARK: - Live force-directed graph

struct ForceGraph: View {
    let pages: [WikiPage]
    let onSelect: (WikiPage) -> Void

    @State private var positions: [String: CGPoint] = [:]
    @State private var velocities: [String: CGPoint] = [:]
    @State private var dragging: String? = nil
    @State private var seeded = false
    @State private var settled = false
    // Physics canvas — larger than the screen so nodes have room to breathe
    @State private var canvas: CGSize = .zero
    @State private var screenSize: CGSize = .zero
    // Zoom and pan transform canvas → screen
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero

    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let sz = geo.size
            ZStack {
                // Edges drawn by mapping physics positions → screen coords
                Canvas { ctx, _ in
                    for edge in edges {
                        guard let a = positions[edge.a], let b = positions[edge.b] else { continue }
                        var path = Path()
                        path.move(to: toScreen(a, screen: sz))
                        path.addLine(to: toScreen(b, screen: sz))
                        ctx.stroke(path, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                    }
                }
                .frame(width: sz.width, height: sz.height)

                // Nodes placed at their screen-space position; drag maps back to canvas space
                ForEach(pages) { page in
                    if let pos = positions[page.id] {
                        GraphNodeView(title: page.title, folder: page.folder, linkCount: page.links.count)
                            .scaleEffect(max(0.3, zoom))
                            .position(toScreen(pos, screen: sz))
                            .gesture(
                                DragGesture(minimumDistance: 4)
                                    .onChanged { v in
                                        dragging = page.id
                                        settled = false
                                        positions[page.id] = toCanvas(v.location, screen: sz)
                                        velocities[page.id] = .zero
                                    }
                                    .onEnded { _ in dragging = nil }
                            )
                            .onTapGesture { onSelect(page) }
                            .opacity(seeded ? 1 : 0)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        guard dragging == nil else { return }
                        pan = CGSize(width: lastPan.width + v.translation.width,
                                     height: lastPan.height + v.translation.height)
                    }
                    .onEnded { _ in guard dragging == nil else { return }; lastPan = pan }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { v in zoom = max(0.05, min(5, lastZoom * v)) }
                    .onEnded { _ in lastZoom = zoom }
            )
            .onAppear {
                screenSize = sz
                guard !seeded else { return }
                // Physics canvas: big enough for all nodes to spread at ~200pt spacing
                let n = CGFloat(max(pages.count, 1))
                let side = max(n * 80, 1000)
                canvas = CGSize(width: side, height: side)
                seed()
                seeded = true
                // Start zoomed out to fit the whole canvas in view
                let fit = min(sz.width / canvas.width, sz.height / canvas.height) * 0.85
                zoom = fit; lastZoom = fit
            }
            .onReceive(timer) { _ in
                guard seeded, !settled, canvas.width > 0 else { return }
                let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                let (newPos, newVel, done) = step(center: center, pinned: dragging)
                positions = newPos
                velocities = newVel
                settled = done
            }
        }
    }

    // MARK: - Coordinate transforms (canvas ↔ screen)

    private func toScreen(_ p: CGPoint, screen: CGSize) -> CGPoint {
        let ccx = canvas.width / 2, ccy = canvas.height / 2
        let scx = screen.width / 2, scy = screen.height / 2
        return CGPoint(
            x: (p.x - ccx) * zoom + scx + pan.width,
            y: (p.y - ccy) * zoom + scy + pan.height
        )
    }

    private func toCanvas(_ p: CGPoint, screen: CGSize) -> CGPoint {
        let ccx = canvas.width / 2, ccy = canvas.height / 2
        let scx = screen.width / 2, scy = screen.height / 2
        let x = (p.x - scx - pan.width) / zoom + ccx
        let y = (p.y - scy - pan.height) / zoom + ccy
        return clampToCanvas(CGPoint(x: x, y: y))
    }

    // MARK: - Seed

    private func seed() {
        let n = max(pages.count, 1)
        let cx = canvas.width / 2, cy = canvas.height / 2
        let r = min(canvas.width, canvas.height) * 0.35
        for (i, page) in pages.enumerated() {
            let angle = (Double(i) / Double(n)) * 2 * .pi
            positions[page.id] = CGPoint(
                x: cx + CGFloat(cos(angle)) * r + CGFloat.random(in: -10...10),
                y: cy + CGFloat(sin(angle)) * r + CGFloat.random(in: -10...10)
            )
            velocities[page.id] = .zero
        }
    }

    // MARK: - Physics step (runs in canvas space, independent of screen size)

    private func step(center: CGPoint, pinned: String?) -> ([String: CGPoint], [String: CGPoint], Bool) {
        var p = positions
        var v = velocities
        var forces: [String: CGPoint] = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, .zero) })

        let n = CGFloat(max(pages.count, 1))
        let repulsion: CGFloat = 8000
        let maxForce: CGFloat = 200            // cap so close nodes don't explode outward
        let springLen: CGFloat = canvas.width / max(n, 6) * 1.5  // natural spacing = canvas / nodeCount
        let springK: CGFloat = 0.025
        let damping: CGFloat = 0.80
        let gravity: CGFloat = 0.006

        for i in 0..<pages.count {
            for j in (i+1)..<pages.count {
                let a = pages[i].id, b = pages[j].id
                guard let pa = p[a], let pb = p[b] else { continue }
                let dx = pa.x - pb.x, dy = pa.y - pb.y
                let dist = max(hypot(dx, dy), 1)
                let f = min(repulsion / (dist * dist), maxForce)
                let nx = f * dx / dist, ny = f * dy / dist
                forces[a]!.x += nx; forces[a]!.y += ny
                forces[b]!.x -= nx; forces[b]!.y -= ny
            }
        }

        for edge in edges {
            guard let pa = p[edge.a], let pb = p[edge.b] else { continue }
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let dist = max(hypot(dx, dy), 1)
            let f = springK * (dist - springLen)
            let nx = f * dx / dist, ny = f * dy / dist
            forces[edge.a]!.x += nx; forces[edge.a]!.y += ny
            forces[edge.b]!.x -= nx; forces[edge.b]!.y -= ny
        }

        var maxSpeed: CGFloat = 0
        for page in pages {
            let id = page.id
            guard id != pinned,
                  var pt = p[id], var vt = v[id], let ft = forces[id] else { continue }
            let deg = CGFloat(page.links.count + 1)
            vt.x = (vt.x + ft.x) * damping + (center.x - pt.x) * gravity * deg
            vt.y = (vt.y + ft.y) * damping + (center.y - pt.y) * gravity * deg
            pt = clampToCanvas(CGPoint(x: pt.x + vt.x, y: pt.y + vt.y))
            p[id] = pt; v[id] = vt
            maxSpeed = max(maxSpeed, hypot(vt.x, vt.y))
        }

        return (p, v, maxSpeed < 0.5)
    }

    private func clampToCanvas(_ pt: CGPoint) -> CGPoint {
        let m: CGFloat = 80
        return CGPoint(x: max(m, min(canvas.width - m, pt.x)),
                       y: max(m, min(canvas.height - m, pt.y)))
    }

    // MARK: - Edge resolution: full path, filename-only, then title

    struct GraphEdge: Identifiable {
        let id: String; let a: String; let b: String
    }

    private var edges: [GraphEdge] {
        var result: [GraphEdge] = []
        var seen = Set<String>()
        var byPath: [String: String] = [:]
        var byTitle: [String: String] = [:]
        for page in pages {
            let idLower = page.id.lowercased()
            byPath[idLower] = page.id
            byPath[page.path.lowercased()] = page.id
            // Also index by filename alone (without folder) so [[pagename]] works
            let filename = URL(fileURLWithPath: idLower).lastPathComponent
            let filenameStem = filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
            byPath[filename] = page.id
            byPath[filenameStem] = page.id
            byTitle[page.title.lowercased()] = page.id
        }

        for page in pages {
            for link in page.links {
                let clean = link.trimmingCharacters(in: .whitespaces).lowercased()
                let withMd = clean.hasSuffix(".md") ? clean : clean + ".md"
                let withoutMd = clean.hasSuffix(".md") ? String(clean.dropLast(3)) : clean
                let targetId = byPath[withMd] ?? byPath[withoutMd] ?? byTitle[withoutMd]
                guard let tid = targetId, tid != page.id else { continue }
                let key = [page.id, tid].sorted().joined(separator: "—")
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(GraphEdge(id: key, a: page.id, b: tid))
            }
        }
        return result
    }
}

struct GraphNodeView: View {
    let title: String
    let folder: String
    let linkCount: Int

    var body: some View {
        VStack(spacing: 5) {
            Circle()
                .fill(folderColor(folder))
                .frame(width: size, height: size)
                .shadow(color: folderColor(folder).opacity(0.25), radius: 2, x: 0, y: 1)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 76)
        }
    }

    private var size: CGFloat { CGFloat(8 + min(linkCount, 8) * 2) }
}

// MARK: - Markdown renderer

struct MarkdownContentView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
    }

    private var lines: [String] {
        text.components(separatedBy: .newlines)
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        if line.hasPrefix("### ") {
            Text(String(line.dropFirst(4)))
                .font(.subheadline).fontWeight(.semibold)
                .padding(.top, 6)
        } else if line.hasPrefix("## ") {
            Text(String(line.dropFirst(3)))
                .font(.headline)
                .padding(.top, 8)
        } else if line.hasPrefix("# ") {
            Text(String(line.dropFirst(2)))
                .font(.title3).bold()
                .padding(.top, 8)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inlineText(String(line.dropFirst(2)))
            }
        } else if line.isEmpty {
            Spacer().frame(height: 2)
        } else {
            inlineText(line)
        }
    }

    private func inlineText(_ s: String) -> some View {
        let attributed = (try? AttributedString(markdown: s,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        return Text(attributed).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Page Detail

struct WikiPageView: View {
    let page: WikiPage
    let wikiStore: WikiStore
    let memoryStore: MemoryStore
    let onNavigate: (WikiPage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMemory: MemoryEntry?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Circle().fill(folderColor(page.folder)).frame(width: 10, height: 10)
                        Text(page.folder.capitalized)
                            .font(.caption)
                            .foregroundStyle(folderColor(page.folder))
                    }
                    Text(page.title).font(.title2).bold()

                    MarkdownContentView(text: displayContent)

                    if !page.links.isEmpty {
                        Divider()
                        Text("Connections").font(.caption).foregroundStyle(.secondary)
                        ForEach(page.links, id: \.self) { link in
                            if let target = findPage(link) {
                                Button { onNavigate(target) } label: {
                                    Label(target.title, systemImage: "link")
                                }
                            }
                        }
                    }
                    if !memoryLinks.isEmpty {
                        Divider()
                        ForEach(memoryLinks, id: \.self) { uuidStr in
                            if let entry = findMemory(uuidStr) {
                                Button { selectedMemory = entry } label: {
                                    Label(
                                        entry.timestamp.formatted(.dateTime.day().month().year().hour().minute()),
                                        systemImage: "brain"
                                    )
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $selectedMemory) { entry in
                MemoryDetailView(entry: entry, photoURL: memoryStore.photoURL(for: entry)) {
                    try? memoryStore.delete(id: entry.id)
                    selectedMemory = nil
                }
            }
        }
    }

    private var rawContent: String { wikiStore.readFile(path: page.path) }

    private var displayContent: String {
        rawContent
            .replacingOccurrences(of: #"\[\[exp:[^\]]+\]\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var memoryLinks: [String] {
        guard let re = try? NSRegularExpression(pattern: #"\[\[exp:([0-9A-Fa-f-]{36})\]\]"#) else { return [] }
        let s = rawContent
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range(at: 1), in: s).map { String(s[$0]) }
        }
    }

    private func findMemory(_ uuidStr: String) -> MemoryEntry? {
        guard let uuid = UUID(uuidString: uuidStr) else { return nil }
        return memoryStore.entries.first { $0.id == uuid }
    }

    private func findPage(_ name: String) -> WikiPage? {
        let clean = name.trimmingCharacters(in: .whitespaces)
        let pages = wikiStore.allPages()
        // Full path match first
        let linkId = clean.hasSuffix(".md") ? clean : clean + ".md"
        if let match = pages.first(where: { $0.id.lowercased() == linkId.lowercased() }) { return match }
        // Filename-only match
        let filename = URL(fileURLWithPath: linkId).lastPathComponent.lowercased()
        return pages.first(where: { URL(fileURLWithPath: $0.id).lastPathComponent.lowercased() == filename })
    }
}
