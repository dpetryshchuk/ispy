import SwiftUI
import MLX

struct DevSettingsView: View {
    let promptConfig: PromptConfig
    let memoryStore: MemoryStore
    let wikiStore: WikiStore
    let gemmaService: GemmaVisionService
    @Binding var devStageOverride: Int?

    @State private var stageEnabled = false
    @State private var stageValue: Double = 0
    @State private var showDeleteExperiencesConfirm = false
    @State private var showDeleteWikiConfirm = false
    @State private var memoryStats: (active: Int, cache: Int, peak: Int) = (0, 0, 0)
    @State private var memoryTimer: Timer?

    var body: some View {
        NavigationStack {
            Form {
                energySection
                stageSection
                promptSection("Memory Instructions", text: Binding(
                    get: { promptConfig.memoryExtraInstructions },
                    set: { promptConfig.memoryExtraInstructions = $0 }
                ))
                promptSection("Consolidation Instructions", text: Binding(
                    get: { promptConfig.consolidationExtraInstructions },
                    set: { promptConfig.consolidationExtraInstructions = $0 }
                ))
                promptSection("Chat Personality", text: Binding(
                    get: { promptConfig.chatPersonalityPrompt },
                    set: { promptConfig.chatPersonalityPrompt = $0 }
                ))
                promptSection("Vision Dream Prompt", text: Binding(
                    get: { promptConfig.visionDreamPrompt },
                    set: { promptConfig.visionDreamPrompt = $0 }
                ))

                Section("Model") {
                    LabeledContent("Gemma backend", value: gemmaService.activeBackend.uppercased())
                    LabeledContent("Gemma state") {
                        switch gemmaService.state {
                        case .needsDownload: Text("Needs download").foregroundStyle(.secondary)
                        case .downloading:   Text("Downloading…").foregroundStyle(.orange)
                        case .loading:       Text("Loading…").foregroundStyle(.orange)
                        case .ready:         Text("Ready").foregroundStyle(.green)
                        case .error(let e):  Text(e).foregroundStyle(.red).font(.caption)
                        }
                    }
                }

                Section("Reset") {
                    Button("Reset Dream Cursor") {
                        wikiStore.resetDreamCursor()
                    }
                    .foregroundStyle(.orange)

                    Button("Delete All Wiki Pages", role: .destructive) {
                        showDeleteWikiConfirm = true
                    }

                    Button("Delete All Experiences", role: .destructive) {
                        showDeleteExperiencesConfirm = true
                    }

                    Button("Reset Prompts to Defaults", role: .destructive) {
                        promptConfig.resetToDefaults()
                    }
                }
                .confirmationDialog(
                    "Delete all \(wikiStore.pageCount()) wiki pages?",
                    isPresented: $showDeleteWikiConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete All Pages", role: .destructive) { wikiStore.deleteAllWikiPages() }
                }
                .confirmationDialog(
                    "Delete all \(memoryStore.entries.count) experiences?",
                    isPresented: $showDeleteExperiencesConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete All", role: .destructive) { memoryStore.deleteAll() }
                }
            }
            .navigationTitle("Dev Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { promptConfig.save() }
                }
            }
            .onAppear {
                stageEnabled = devStageOverride != nil
                stageValue = Double(devStageOverride ?? 0)
                startMemoryMonitor()
            }
            .onDisappear {
                memoryTimer?.invalidate()
            }
        }
    }

    private var energySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.yellow)
                    Text("Neural Energy")
                        .font(.headline)
                    Spacer()
                    Text("\(formatBytes(memoryStats.active)) active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.3))

                        let maxMemory: CGFloat = 500 * 1024 * 1024
                        let usedFraction = min(CGFloat(memoryStats.active) / maxMemory, 1.0)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(energyGradient(for: usedFraction))
                            .frame(width: geometry.size.width * usedFraction)
                    }
                }
                .frame(height: 12)

                HStack {
                    Text("Cache: \(formatBytes(memoryStats.cache))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Peak: \(formatBytes(memoryStats.peak))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func energyGradient(for fraction: CGFloat) -> LinearGradient {
        if fraction > 0.8 {
            return LinearGradient(
                colors: [.red, .orange],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else if fraction > 0.5 {
            return LinearGradient(
                colors: [.orange, .yellow],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            return LinearGradient(
                colors: [.green, .mint],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 100 {
            return String(format: "%.0fMB", mb)
        } else if mb >= 10 {
            return String(format: "%.1fMB", mb)
        } else {
            return String(format: "%.2fMB", mb)
        }
    }

    private func startMemoryMonitor() {
        updateMemory()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            updateMemory()
        }
    }

    private func updateMemory() {
        memoryStats = (
            active: Memory.activeMemory,
            cache: Memory.cacheMemory,
            peak: Memory.peakMemory
        )
    }

    private var stageSection: some View {
        Section("Shape Stage Override") {
            Toggle("Override Stage", isOn: $stageEnabled)
                .onChange(of: stageEnabled) { _, on in
                    devStageOverride = on ? Int(stageValue) : nil
                }
            if stageEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Stage \(Int(stageValue))")
                        Spacer()
                        Text(stageNames[Int(stageValue)].capitalized)
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $stageValue, in: 0...6, step: 1)
                        .onChange(of: stageValue) { _, v in
                            devStageOverride = Int(v)
                        }
                }
            }
        }
    }

    private func promptSection(_ title: String, text: Binding<String>) -> some View {
        Section(title) {
            TextEditor(text: text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 120)
        }
    }

}
