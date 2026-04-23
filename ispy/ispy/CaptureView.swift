import SwiftUI
import PhotosUI

struct CaptureView: View {
    let gemmaService: GemmaVisionService
    let memoryStore: MemoryStore

    @StateObject private var camera = CameraCapture()

    @State private var selectedImage: UIImage?
    @State private var description: String?
    @State private var isAnalyzing = false
    @State private var photoItem: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var saved = false

    // Context input
    enum ContextMode { case none, voice, text }
    @State private var contextMode: ContextMode = .none
    @State private var context = ""
    @State private var recorder = SpeechRecorder()
    @State private var textDraft = ""

    var body: some View {
        NavigationStack {
            Group {
                if let image = selectedImage {
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
            .onChange(of: photoItem) { _, newItem in
                Task {
                    guard let newItem else { return }
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        selectedImage = image
                        reset()
                        // Auto-analyze immediately if model is ready
                        if gemmaService.state.isReady { analyze(image: image) }
                    }
                }
            }
            .onAppear { camera.start() }
            .onDisappear { camera.stop() }
        }
    }

    // MARK: - Camera (no image selected)

    private var cameraFlow: some View {
        ZStack {
            if camera.isReady {
                CameraView(session: camera.session)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                ProgressView().tint(.white)
            }

            VStack {
                Spacer()
                cameraControls
                    .padding(.bottom, 24)
            }
        }
        .overlay(alignment: .top) {
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.red.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
            }
        }
    }

    private var cameraControls: some View {
        HStack(spacing: 48) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo.fill")
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
                    if let image, gemmaService.state.isReady { analyze(image: image) }
                }
            } label: {
                ZStack {
                    Circle().fill(Color.white).frame(width: 72, height: 72)
                    Circle().stroke(Color.white, lineWidth: 3).frame(width: 84, height: 84)
                }
            }

            // spacer to balance layout
            Color.clear.frame(width: 44, height: 44)
        }
    }

    // MARK: - Image + Analyze flow

    private func imageFlow(image: UIImage) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .cornerRadius(10)

                if isAnalyzing {
                    VStack(spacing: 16) {
                        IspyShapeView(
                            stageIndex: evolutionStageIndex(for: memoryStore.entries.count),
                            size: 90,
                            isAnalyzing: true
                        )
                        Text("Thinking…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if let desc = description {
                    resultSection(image: image, desc: desc)
                } else {
                    // Model not ready — show manual trigger option
                    VStack(spacing: 8) {
                        Button("Analyze") { analyze(image: image) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!gemmaService.state.isReady)
                        Button("Retake") { clearAll() }.buttonStyle(.bordered)
                        if !gemmaService.state.isReady {
                            Text("Load Gemma 4 in the Capture tab first")
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }

                if let error = errorMessage {
                    Text(error).foregroundStyle(.red).font(.caption).multilineTextAlignment(.center)
                }
                // Bottom padding so content stays visible above keyboard
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
                Text("Saved to Salients").foregroundStyle(.green).font(.caption)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        context = ""
                        contextMode = .none
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

    // MARK: - Toolbar indicator

    @ViewBuilder
    private var modelStatusIndicator: some View {
        switch gemmaService.state {
        case .needsDownload:
            Button("Get Model") { Task { await gemmaService.download() } }.font(.caption)
        case .downloading:
            ProgressView(value: gemmaService.downloadProgress).frame(width: 60).scaleEffect(0.8)
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
            do { description = try await gemmaService.describe(image: image) }
            catch { errorMessage = error.localizedDescription }
            isAnalyzing = false
        }
    }

    private func saveEntry(image: UIImage, description: String) {
        do { try memoryStore.save(image: image, description: description); saved = true }
        catch { errorMessage = error.localizedDescription }
    }

    private func reset() {
        description = nil; errorMessage = nil; photoItem = nil; saved = false
        context = ""; textDraft = ""; contextMode = .none
        if recorder.isRecording { recorder.stop() }
    }

    private func clearAll() {
        selectedImage = nil; reset()
        camera.start()
    }
}
