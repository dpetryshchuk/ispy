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
            .frame(maxHeight: 160)

            if saved {
                Button("Clear") { clearAll() }
                    .buttonStyle(.bordered)
                Text("Saved ✓").foregroundStyle(.green).font(.caption)
            } else {
                HStack(spacing: 16) {
                    Button("Save") { saveEntry(image: image, description: desc) }
                        .buttonStyle(.borderedProminent)
                    Button("Clear") { clearAll() }
                        .buttonStyle(.bordered)
                }
            }
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
    }

    private func clearAll() {
        selectedImage = nil
        reset()
    }
}
