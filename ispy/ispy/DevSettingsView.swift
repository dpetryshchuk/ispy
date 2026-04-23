import SwiftUI

struct DevSettingsView: View {
    let promptConfig: PromptConfig
    @Binding var devStageOverride: Int?

    @State private var stageEnabled = false
    @State private var stageValue: Double = 0

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

                Section {
                    Button("Reset All to Defaults", role: .destructive) {
                        promptConfig.resetToDefaults()
                    }
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
