import SwiftUI
import PhotosUI

// MARK: - Batch entry

struct BatchEntry: Identifiable {
    let id = UUID()
    var image: UIImage?
    var status: Status = .loading

    enum Status {
        case loading, analyzing, saved, failed(String)

        var icon: String {
            switch self {
            case .loading:   return "hourglass"
            case .analyzing: return "sparkles"
            case .saved:     return "checkmark"
            case .failed:    return "xmark"
            }
        }

        var isActive: Bool {
            switch self { case .loading, .analyzing: return true; default: return false }
        }
    }
}

// MARK: - CaptureView

struct CaptureView: View {
    let fastVLMService: FastVLMVisionService
    let memoryStore: MemoryStore

    @StateObject private var camera = CameraCapture()

    // Single-image (camera) flow
    @State private var selectedImage: UIImage?
    @State private var description: String?
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var saved = false

    // Multi-image (gallery) flow
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var batch: [BatchEntry] = []

    // Context input (single-image)
    enum ContextMode { case none, voice, text }
    @State private var contextMode: ContextMode = .none
    @State private var context = ""
    @State private var recorder = SpeechRecorder()
    @State private var textDraft = ""

    var body: some View {
        NavigationStack {
            Group {
                if !batch.isEmpty {
                    batchFlow
                } else if let image = selectedImage {
                    imageFlow(image: image)
                } else {
                    cameraFlow
                }
            }
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    modelStatusIndicator
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: photoItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                let captured = newItems
                photoItems = []
                if captured.count == 1 {
                    // Single pick — use existing single-image flow
                    Task {
                        guard let data = try? await captured[0].loadTransferable(type: Data.self),
                              let image = UIImage(data: data) else { return }
                        selectedImage = image
                        reset()
                        if fastVLMService.state.isReady { analyze(image: image) }
                    }
                } else {
                    // Multi-pick — batch flow
                    startBatch(captured)
                }
            }
            .onAppear {
                camera.start()
                Task { await fastVLMService.load() }
            }
            .onDisappear { camera.stop() }
            .onChange(of: fastVLMService.state) { _, newState in
                if newState == .ready, let image = selectedImage, description == nil, !isAnalyzing {
                    analyze(image: image)
                }
            }
        }
    }

    // MARK: - Camera flow

    private var cameraFlow: some View {
        ZStack {
            if camera.isReady {
                CameraView(session: camera.session).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                ProgressView().tint(.white)
            }

            VStack {
                Spacer()
                cameraControls.padding(.bottom, 24)
            }
        }
        .overlay(alignment: .top) {
            if let error = errorMessage {
                Text(error)
                    .font(.caption).foregroundStyle(.white)
                    .padding(8)
                    .background(Color.red.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
            }
        }
    }

    private var cameraControls: some View {
        HStack(spacing: 48) {
            PhotosPicker(selection: $photoItems, maxSelectionCount: 30, matching: .images) {
                Image(systemName: "photo.stack.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.4))
                    .clipShape(Circle())
            }

            Button {
                camera.capturePhoto { image in
                    selectedImage = image
                    errorMessage = image == nil ? "Capture failed" : nil
                    if let image, fastVLMService.state.isReady { analyze(image: image) }
                }
            } label: {
                ZStack {
                    Circle().fill(Color.white).frame(width: 72, height: 72)
                    Circle().stroke(Color.white, lineWidth: 3).frame(width: 84, height: 84)
                }
            }

            Color.clear.frame(width: 44, height: 44)
        }
    }

    // MARK: - Batch flow (multi-select)

    private var batchFlow: some View {
        let isProcessing = batch.contains { $0.status.isActive }
        let savedCount  = batch.filter { if case .saved = $0.status { return true }; return false }.count
        let allDone     = !isProcessing

        return VStack(spacing: 0) {
            Spacer()

            IspyShapeView(
                stageIndex: evolutionStageIndex(for: memoryStore.entries.count),
                size: 80,
                isAnalyzing: isProcessing
            )
            .padding(.bottom, 10)

            Group {
                if allDone {
                    Text("\(savedCount) experience\(savedCount == 1 ? "" : "s") added")
                } else {
                    Text("Analyzing \(savedCount + 1) of \(batch.count)…")
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.bottom, 20)

            Spacer()

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(batch) { entry in
                        BatchThumbnailCell(entry: entry)
                    }
                }
                .padding(.horizontal)
            }
            .frame(maxHeight: 360)

            if allDone {
                Button("Done") {
                    batch = []
                    camera.start()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
        }
    }

    private func startBatch(_ items: [PhotosPickerItem]) {
        camera.stop()
        batch = items.map { _ in BatchEntry() }
        Task { @MainActor in
            for i in items.indices {
                guard let data = try? await items[i].loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    batch[i].status = .failed("Could not load")
                    continue
                }
                batch[i].image = image
                batch[i].status = .analyzing

                do {
                    let desc = try await fastVLMService.describe(image: image)
                    try? memoryStore.save(image: image, description: desc)
                    batch[i].status = .saved
                } catch {
                    batch[i].status = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Single-image flow

    private func imageFlow(image: UIImage) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 240)
                    .cornerRadius(10)

                if isAnalyzing {
                    VStack(spacing: 12) {
                        IspyShapeView(
                            stageIndex: evolutionStageIndex(for: memoryStore.entries.count),
                            size: 90,
                            isAnalyzing: true
                        )
                        if fastVLMService.streamingOutput.isEmpty {
                            Text("Analyzing…")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    Text(fastVLMService.streamingOutput)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id("stream")
                                        .padding(.horizontal, 4)
                                }
                                .frame(maxHeight: 110)
                                .onChange(of: fastVLMService.streamingOutput) { _, _ in
                                    withAnimation { proxy.scrollTo("stream", anchor: .bottom) }
                                }
                            }
                        }
                    }
                } else if let desc = description {
                    resultSection(image: image, desc: desc)
                } else {
                    VStack(spacing: 8) {
                        Button("Analyze") { analyze(image: image) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!fastVLMService.state.isReady)
                        Button("Retake") { clearAll() }.buttonStyle(.bordered)
                        if case .downloading(let p) = fastVLMService.state {
                            ProgressView(value: p)
                                .frame(width: 120)
                            Text("Downloading model…")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if fastVLMService.state == .loading {
                            ProgressView()
                            Text("Loading model…")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if fastVLMService.state == .idle {
                            Text("Loading FastVLM…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let error = errorMessage {
                    Text(error).foregroundStyle(.red).font(.caption).multilineTextAlignment(.center)
                }
                Color.clear.frame(height: 120)
            }
            .padding()
        }
    }

    private func resultSection(image: UIImage, desc: String) -> some View {
        VStack(spacing: 12) {
            ScrollView {
                Text(desc).font(.subheadline).padding(.horizontal)
            }
            .frame(maxHeight: 110)

            contextInputView

            if saved {
                Button("New Capture") { clearAll() }.buttonStyle(.borderedProminent)
                Text("Saved to Experiences").foregroundStyle(.green).font(.caption)
            } else {
                HStack(spacing: 16) {
                    Button("Save") {
                        let full = context.isEmpty ? desc : desc + "\n\nContext: " + context
                        saveEntry(image: image, description: full)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Retake") { clearAll() }.buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private var contextInputView: some View {
        VStack(spacing: 8) {
            if !context.isEmpty {
                HStack(alignment: .top) {
                    Text(context)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        context = ""; contextMode = .none
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.caption)
                    }
                }
                .padding(.horizontal, 4)
            }

            if contextMode == .voice && recorder.isRecording {
                Text(recorder.transcript.isEmpty ? "Listening…" : recorder.transcript)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            }

            if contextMode == .text {
                HStack(spacing: 8) {
                    TextField("Add context…", text: $textDraft, axis: .vertical)
                        .lineLimit(1...3).font(.subheadline).textFieldStyle(.roundedBorder)
                    Button("Done") {
                        context = textDraft; textDraft = ""; contextMode = .none
                    }
                    .font(.subheadline).disabled(textDraft.isEmpty)
                }
            }

            if let err = recorder.error {
                Text(err).font(.caption2).foregroundStyle(.red)
            }

            if context.isEmpty || contextMode != .none {
                HStack(spacing: 12) {
                    Button {
                        if contextMode == .voice && recorder.isRecording {
                            context = recorder.stop(); contextMode = .none
                        } else {
                            textDraft = ""; contextMode = .voice; context = ""; recorder.start()
                        }
                    } label: {
                        Label(
                            contextMode == .voice && recorder.isRecording ? "Stop" : "Voice",
                            systemImage: contextMode == .voice && recorder.isRecording ? "stop.fill" : "mic"
                        )
                        .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(contextMode == .voice ? Color.red.opacity(0.1) : Color(.systemGray6))
                        .foregroundStyle(contextMode == .voice && recorder.isRecording ? .red : .primary)
                        .clipShape(Capsule())
                    }

                    Button {
                        if recorder.isRecording { recorder.stop() }
                        contextMode = contextMode == .text ? .none : .text
                    } label: {
                        Label("Text", systemImage: "text.bubble")
                            .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6)
                            .background(contextMode == .text ? Color.accentColor.opacity(0.1) : Color(.systemGray6))
                            .foregroundStyle(contextMode == .text ? Color.accentColor : Color.primary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var modelStatusIndicator: some View {
        switch fastVLMService.state {
        case .idle:
            Button("Load FastVLM") { Task { await fastVLMService.load() } }.font(.caption)
        case .downloading(let p):
            ProgressView(value: p).frame(width: 60).scaleEffect(0.8)
        case .loading:
            ProgressView().scaleEffect(0.7)
        case .error:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
        case .ready:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func analyze(image: UIImage) {
        isAnalyzing = true; errorMessage = nil
        Task {
            do { description = try await fastVLMService.describe(image: image) }
            catch { errorMessage = error.localizedDescription }
            isAnalyzing = false
        }
    }

    private func saveEntry(image: UIImage, description: String) {
        do { try memoryStore.save(image: image, description: description); saved = true }
        catch { errorMessage = error.localizedDescription }
    }

    private func reset() {
        description = nil; errorMessage = nil; saved = false
        context = ""; textDraft = ""; contextMode = .none
        if recorder.isRecording { recorder.stop() }
    }

    private func clearAll() {
        selectedImage = nil; reset()
        camera.start()
    }
}

// MARK: - Batch thumbnail cell

struct BatchThumbnailCell: View {
    let entry: BatchEntry

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let img = entry.image {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                } else {
                    Color(.tertiarySystemBackground)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            badge.padding(5)
        }
    }

    @ViewBuilder
    private var badge: some View {
        ZStack {
            Circle()
                .fill(badgeColor)
                .frame(width: 22, height: 22)
            if case .loading = entry.status {
                ProgressView().scaleEffect(0.45).tint(.white)
            } else if case .analyzing = entry.status {
                Image(systemName: entry.status.icon)
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            } else {
                Image(systemName: entry.status.icon)
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            }
        }
    }

    private var badgeColor: Color {
        switch entry.status {
        case .loading:   return Color(.systemGray3)
        case .analyzing: return .purple
        case .saved:     return .green
        case .failed:    return .red
        }
    }
}
