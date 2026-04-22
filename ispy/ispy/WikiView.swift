import SwiftUI
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
                    Text("Files").tag(false)
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
            .navigationTitle("Wiki")
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

struct ForceGraph: View {
    let pages: [WikiPage]
    let onSelect: (WikiPage) -> Void
    @State private var positions: [String: CGPoint] = [:]
    @State private var ready = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(edges, id: \.id) { edge in
                    if let a = positions[edge.a], let b = positions[edge.b] {
                        Path { p in p.move(to: a); p.addLine(to: b) }
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    }
                }
                ForEach(pages) { page in
                    if let pos = positions[page.id] {
                        GraphNodeView(title: page.title, folder: page.folder, linkCount: page.links.count)
                            .position(pos)
                            .gesture(DragGesture().onChanged { v in positions[page.id] = v.location })
                            .onTapGesture { onSelect(page) }
                            .opacity(ready ? 1 : 0)
                    }
                }
            }
            .onAppear {
                guard !ready else { return }
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                // Seed in circle first so they're visible immediately, then simulate
                seedPositions(center: center, size: geo.size)
                ready = true
                Task.detached(priority: .userInitiated) {
                    let result = simulate(
                        seed: await MainActor.run { positions },
                        pages: pages,
                        edges: edges,
                        center: center,
                        size: geo.size
                    )
                    await MainActor.run { positions = result }
                }
            }
        }
    }

    private func seedPositions(center: CGPoint, size: CGSize) {
        let n = max(pages.count, 1)
        let radius = min(size.width, size.height) * 0.35
        for (i, page) in pages.enumerated() {
            let angle = (Double(i) / Double(n)) * 2 * .pi
            positions[page.id] = CGPoint(
                x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius
            )
        }
    }

    // Nonisolated pure function — runs off main actor
    private nonisolated func simulate(
        seed: [String: CGPoint],
        pages: [WikiPage],
        edges: [GraphEdge],
        center: CGPoint,
        size: CGSize
    ) -> [String: CGPoint] {
        var pos = seed
        var vel: [String: CGPoint] = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, CGPoint.zero) })

        let repulsion: CGFloat = 4000
        let springLen: CGFloat = 120
        let springK: CGFloat = 0.04
        let damping: CGFloat = 0.75
        let gravity: CGFloat = 0.015

        for _ in 0..<300 {
            var forces: [String: CGPoint] = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, CGPoint.zero) })

            // Repulsion
            for i in 0..<pages.count {
                for j in (i + 1)..<pages.count {
                    let a = pages[i].id, b = pages[j].id
                    guard let pa = pos[a], let pb = pos[b] else { continue }
                    let dx = pa.x - pb.x, dy = pa.y - pb.y
                    let d = max(hypot(dx, dy), 1)
                    let f = repulsion / (d * d)
                    forces[a]!.x += f * dx / d; forces[a]!.y += f * dy / d
                    forces[b]!.x -= f * dx / d; forces[b]!.y -= f * dy / d
                }
            }

            // Spring attraction along edges
            for edge in edges {
                guard let pa = pos[edge.a], let pb = pos[edge.b] else { continue }
                let dx = pb.x - pa.x, dy = pb.y - pa.y
                let d = max(hypot(dx, dy), 1)
                let f = springK * (d - springLen)
                forces[edge.a]!.x += f * dx / d; forces[edge.a]!.y += f * dy / d
                forces[edge.b]!.x -= f * dx / d; forces[edge.b]!.y -= f * dy / d
            }

            // Integrate
            for page in pages {
                let id = page.id
                guard var p = pos[id], var v = vel[id], let f = forces[id] else { continue }
                // Degree-weighted gravity pulls connected nodes toward center
                let deg = CGFloat(page.links.count + 1)
                v.x = (v.x + f.x) * damping + (center.x - p.x) * gravity * deg
                v.y = (v.y + f.y) * damping + (center.y - p.y) * gravity * deg
                p.x = max(50, min(size.width - 50, p.x + v.x))
                p.y = max(50, min(size.height - 50, p.y + v.y))
                pos[id] = p; vel[id] = v
            }
        }
        return pos
    }

    struct GraphEdge: Identifiable {
        let id: String; let a: String; let b: String
    }

    private var edges: [GraphEdge] {
        var result: [GraphEdge] = []
        var seen = Set<String>()
        for page in pages {
            for link in page.links {
                let clean = link
                    .replacingOccurrences(of: "[[", with: "")
                    .replacingOccurrences(of: "]]", with: "")
                    .trimmingCharacters(in: .whitespaces)
                let linkId = clean.hasSuffix(".md") ? clean : clean + ".md"
                guard pages.contains(where: { $0.id == linkId }) else { continue }
                let key = [page.id, linkId].sorted().joined(separator: "—")
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(GraphEdge(id: key, a: page.id, b: linkId))
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
        VStack(spacing: 2) {
            Circle()
                .fill(folderColor(folder).opacity(0.8))
                .frame(width: size, height: size)
                .shadow(color: folderColor(folder).opacity(0.3), radius: 4)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var size: CGFloat { CGFloat(12 + min(linkCount, 8) * 3) }
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
                    Text(displayContent).foregroundStyle(.primary)
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
                        Text("Sources").font(.caption).foregroundStyle(.secondary)
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
        rawContent.replacingOccurrences(of: #"\[\[memory:[^\]]+\]\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var memoryLinks: [String] {
        guard let re = try? NSRegularExpression(pattern: #"\[\[memory:([0-9A-Fa-f-]{36})\]\]"#) else { return [] }
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
        let linkId = clean.hasSuffix(".md") ? clean : clean + ".md"
        return wikiStore.allPages().first { $0.id.lowercased() == linkId.lowercased() }
    }
}
