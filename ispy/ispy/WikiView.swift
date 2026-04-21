import SwiftUI
import UIKit

struct WikiView: View {
    let wikiStore: WikiStore
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
                    WikiGraphView(wikiStore: wikiStore) { p in
                        selectedPage = p
                    }
                } else {
                    WikiFilesView(wikiStore: wikiStore) { p in
                        selectedPage = p
                    }
                }
            }
            .navigationTitle("Wiki")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let url = URL(string: "shareddocuments://") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                }
            }
            .sheet(item: $selectedPage) { page in
                WikiPageView(page: page, wikiStore: wikiStore) { target in
                    selectedPage = target
                }
            }
        }
    }
}

// MARK: - Files

struct WikiFilesView: View {
    let wikiStore: WikiStore
    let onSelect: (WikiPage) -> Void

    var body: some View {
        let pages = wikiStore.allPages()
        if pages.isEmpty {
            ContentUnavailableView("No pages yet", systemImage: "folder", description: Text("Dream to build wiki."))
        } else {
            List {
                ForEach(pages.sorted(by: { $0.path < $1.path })) { page in
                    Button { onSelect(page) } label: {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.purple)
                            Text(page.title)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

// MARK: - Graph

struct WikiGraphView: View {
    let wikiStore: WikiStore
    let onSelect: (WikiPage) -> Void

    var body: some View {
        let pages = wikiStore.allPages()
        if pages.isEmpty {
            ContentUnavailableView("No pages yet", systemImage: "map", description: Text("Dream to build wiki."))
        } else {
            GraphCanvas(pages: pages, onSelect: onSelect)
        }
    }
}

struct GraphNode: Identifiable {
    let id: String
    let title: String
    let links: [String]
    var position: CGPoint
}

struct GraphCanvas: View {
    let pages: [WikiPage]
    let onSelect: (WikiPage) -> Void
    @State private var positions: [String: CGPoint] = [:]

    var body: some View {
        GeometryReader { geo in
            let cx = geo.size.width / 2
            let cy = geo.size.height / 2
            let radius = min(geo.size.width, geo.size.height) / 2 - 60

            ZStack {
                ForEach(edgePairs, id: \.2) { aKey, bKey, _ in
                    let a = positions[aKey] ?? .zero
                    let b = positions[bKey] ?? .zero
                    Edge(from: a, to: b)
                }

                ForEach(pages) { page in
                    let pos = positions[page.id] ?? .zero
                    GraphNodeView(title: page.title, linkCount: page.links.count)
                        .position(pos)
                        .gesture(DragGesture().onChanged { v in positions[page.id] = v.location })
                        .onTapGesture { onSelect(page) }
                }
            }
            .onAppear {
                layoutNodes(cx: cx, cy: cy, radius: radius)
            }
        }
    }

    private var edgePairs: [(String, String, Int)] {
        var pairs: [(String, String, Int)] = []
        for (pi, page) in pages.enumerated() {
            for link in page.links {
                let clean = link.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "").trimmingCharacters(in: .whitespaces)
                let linkId = clean.hasSuffix(".md") ? clean : clean + ".md"
                let pair = page.id < linkId ? (page.id, linkId) : (linkId, page.id)
                if !pairs.contains(where: { $0.0 == pair.0 && $0.1 == pair.1 }) {
                    if pages.contains(where: { $0.id == linkId }) {
                        pairs.append((pair.0, pair.1, pairs.count))
                    }
                }
            }
        }
        return pairs
    }

    private func layoutNodes(cx: CGFloat, cy: CGFloat, radius: CGFloat) {
        let n = pages.count
        for (i, page) in pages.enumerated() {
            let angle = (Double(i) / Double(n)) * 2 * .pi - .pi / 2
            positions[page.id] = CGPoint(
                x: cx + CGFloat(cos(angle)) * radius,
                y: cy + CGFloat(sin(angle)) * radius
            )
        }
    }
}

struct GraphNodeView: View {
    let title: String
    let linkCount: Int

    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(.purple.opacity(0.7))
                .frame(width: size, height: size)
                .shadow(color: .purple.opacity(0.3), radius: 4)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var size: CGFloat { CGFloat(14 + min(linkCount, 5) * 3) }
}

struct Edge: View {
    let from: CGPoint
    let to: CGPoint

    var body: some View {
        Path { p in
            p.move(to: from)
            p.addLine(to: to)
        }.stroke(.purple.opacity(0.2), lineWidth: 1)
    }
}

// MARK: - Page Detail

struct WikiPageView: View {
    let page: WikiPage
    let wikiStore: WikiStore
    let onNavigate: (WikiPage) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(page.title).font(.title2).bold()
                    Text(fullContent).foregroundStyle(.primary)
                    if !page.links.isEmpty {
                        Divider()
                        Text("Connections").font(.caption).foregroundStyle(.secondary)
                        ForEach(page.links, id: \.self) { link in
                            let clean = link.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
                            if let target = findPage(clean) {
                                Button { onNavigate(target) } label: {
                                    Label(clean, systemImage: "link")
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
        }
    }

    private var fullContent: String { wikiStore.readFile(path: page.path) }

    private func findPage(_ name: String) -> WikiPage? {
        let clean = name.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "").trimmingCharacters(in: .whitespaces)
        let linkId = clean.hasSuffix(".md") ? clean : clean + ".md"
        let lower = linkId.lowercased()
        return wikiStore.allPages().first { $0.id.lowercased() == lower }
    }
}