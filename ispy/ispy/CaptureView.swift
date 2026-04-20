import SwiftUI
import PhotosUI

struct CaptureView: View {
    let service: LLMService
    let memoryStore: MemoryStore

    @State private var selectedImage: UIImage?
    @State private var description: String?
    @State private var isAnalyzing = false
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var saved = false

    private func makeVisionService() -> VisionService? {
        guard let inference = service.inference else { return nil }
        return VisionService(inference: inference)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image = selectedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 300)
                        .cornerRadius(8)

                    if isAnalyzing {
                        ProgressView("Analyzing...")
                    } else if let desc = description {
                        ScrollView {
                            Text(desc).padding(.horizontal)
                        }
                        .frame(maxHeight: 150)

                        if saved {
                            Text("Saved ✓").foregroundStyle(.green)
                        } else {
                            HStack(spacing: 16) {
                                Button("Save") { saveEntry(image: image, description: desc) }
                                    .buttonStyle(.borderedProminent)
                                Button("Clear") { clear() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    } else {
                        HStack(spacing: 16) {
                            Button("Analyze") { analyze(image: image) }
                                .buttonStyle(.borderedProminent)
                            Button("Clear") { clear() }
                                .buttonStyle(.bordered)
                        }
                    }
                } else {
                    Spacer()
                    HStack(spacing: 32) {
                        Button {
                            showCamera = true
                        } label: {
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
                    description = nil
                }
            }
            .onChange(of: photoItem) { _, newItem in
                Task {
                    guard let newItem else { return }
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        selectedImage = image
                        description = nil
                        saved = false
                    }
                }
            }
        }
    }

    private func analyze(image: UIImage) {
        guard let vision = makeVisionService() else {
            errorMessage = "Model not ready"
            return
        }
        isAnalyzing = true
        errorMessage = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try vision.describe(image: image)
                }.value
                description = result
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

    private func clear() {
        selectedImage = nil
        description = nil
        errorMessage = nil
        photoItem = nil
        saved = false
    }
}
