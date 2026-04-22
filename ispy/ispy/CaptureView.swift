import SwiftUI
import PhotosUI

struct CaptureView: View {
    let gemmaService: GemmaVisionService
    let memoryStore: MemoryStore

    @State private var selectedImage: UIImage?
    @State private var description: String?
    @State private var isAnalyzing = false
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var saved = false
    @State private var recorder = SpeechRecorder()
    @State private var voiceContext = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                modelStatusBanner

                if let image = selectedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .cornerRadius(8)

                    if isAnalyzing {
                        ProgressView("Analyzing with Gemma 4…")
                    } else if let desc = description {
                        resultView(image: image, desc: desc)
                    } else {
                        HStack(spacing: 16) {
                            Button("Analyze") { analyze(image: image) }
                                .buttonStyle(.borderedProminent)
                                .disabled(!gemmaService.state.isReady)
                            Button("Clear") { clearAll() }
                                .buttonStyle(.bordered)
                        }
                    }
                } else {
                    Spacer()
                    pickerButtons
                    Spacer()
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .navigationTitle("Capture")
            .fullScreenCover(isPresented: $showCamera) {
                CameraView { image in
                    selectedImage = image
                    reset()
                }
            }
            .onChange(of: photoItem) { _, newItem in
                Task {
                    guard let newItem else { return }
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        selectedImage = image
                        reset()
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var modelStatusBanner: some View {
        switch gemmaService.state {
        case .needsDownload:
            VStack(spacing: 8) {
                Text("Gemma 4 needed for image analysis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Download Gemma 4 (~2.6 GB)") {
                    Task { await gemmaService.download() }
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        case .downloading:
            VStack(spacing: 4) {
                ProgressView(value: gemmaService.downloadProgress)
                    .padding(.horizontal)
                Text("Downloading Gemma 4… \(Int(gemmaService.downloadProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Loading Gemma 4…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .error(let msg):
            Text("Error: \(msg)")
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        case .ready:
            EmptyView()
        }
    }

    private var pickerButtons: some View {
        HStack(spacing: 32) {
            Button { showCamera = true } label: {
                VStack(spacing: 8) {
                    Image(systemName: "camera.fill").font(.largeTitle)
                    Text("Camera").font(.caption)
                }
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                VStack(spacing: 8) {
                    Image(systemName: "photo.fill").font(.largeTitle)
                    Text("Gallery").font(.caption)
                }
            }
        }
    }

    private func resultView(image: UIImage, desc: String) -> some View {
        VStack(spacing: 12) {
            ScrollView {
                Text(desc).padding(.horizontal)
            }
            .frame(maxHeight: 120)

            voiceInputView

            if saved {
                Button("Clear") { clearAll() }
                    .buttonStyle(.bordered)
                Text("Saved ✓").foregroundStyle(.green).font(.caption)
            } else {
                HStack(spacing: 16) {
                    Button("Save") {
                        let full = voiceContext.isEmpty ? desc : desc + "\n\nContext: " + voiceContext
                        saveEntry(image: image, description: full)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Clear") { clearAll() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var voiceInputView: some View {
        VStack(spacing: 6) {
            if !voiceContext.isEmpty {
                Text(voiceContext)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            } else if recorder.isRecording {
                Text(recorder.transcript.isEmpty ? "Listening…" : recorder.transcript)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            if let err = recorder.error {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
            Button {
                if recorder.isRecording {
                    voiceContext = recorder.stop()
                } else {
                    voiceContext = ""
                    recorder.start()
                }
            } label: {
                Label(
                    recorder.isRecording ? "Stop Recording" : "Add Voice Context",
                    systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.circle"
                )
                .font(.subheadline)
            }
            .foregroundStyle(recorder.isRecording ? .red : .accentColor)
        }
    }

    // MARK: - Actions

    private func analyze(image: UIImage) {
        isAnalyzing = true
        errorMessage = nil
        Task {
            do {
                description = try await gemmaService.describe(image: image)
            } catch {
                errorMessage = error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    private func saveEntry(image: UIImage, description: String) {
        do {
            try memoryStore.save(image: image, description: description)
            saved = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reset() {
        description = nil
        errorMessage = nil
        photoItem = nil
        saved = false
        voiceContext = ""
        if recorder.isRecording { recorder.stop() }
    }

    private func clearAll() {
        selectedImage = nil
        reset()
    }
}
