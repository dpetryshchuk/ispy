import SwiftUI

struct DevSettingsView: View {
    let promptConfig: PromptConfig
    let memoryStore: MemoryStore
    let wikiStore: WikiStore
    @Binding var devStageOverride: Int?

    @State private var stageEnabled = false
    @State private var stageValue: Double = 0
    @State private var showDeleteExperiencesConfirm = false
    @State private var showDeleteWikiConfirm = false

    var body: some View {
        NavigationStack {
            Form {
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
            }
        }
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
                        Text(stageName(Int(stageValue)))
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

    private func stageName(_ index: Int) -> String {
        let names = ["Point", "Line", "Triangle", "Diamond", "Pentagon", "Hexagon", "Star"]
        guard index >= 0, index < names.count else { return "" }
        return names[index]
    }
}
