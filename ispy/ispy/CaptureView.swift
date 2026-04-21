import SwiftUI
import PhotosUI

struct CaptureView: View {
    let llmService: LLMService
    let memoryStore: MemoryStore

    @State private var selectedImage: UIImage?
    @State private var quickDescription: String?
    @State private var dreamDescription: String?
    @State private var isAnalyzing = false
    @State private var isDreaming = false
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var savedEntryID: UUID?

    private let quickVision = QuickVisionService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image = selectedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .cornerRadius(8)

                    if isAnalyzing {
                        ProgressView("Analyzing...")
                    } else if isDreaming {
                        dreamProgressView
                    } else if let dream = dreamDescription {
                        dreamResultView(dream: dream)
                    } else if let quick = quickDescription {
                        quickResultView(image: image, quick: quick)
                    } else {
                        analyzeButtons(image: image)
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
            .onChange(of: llmService.state) { _, newState in
                guard isDreaming else { return }
                switch newState {
                case .idle:
                    llmService.loadModel()
                case .ready:
                    runDreamInference()
                case .error(let msg):
                    errorMessage = msg
                    isDreaming = false
                default:
                    break
                }
            }
        }
    }

    // MARK: - Subviews

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

    private func analyzeButtons(image: UIImage) -> some View {
        HStack(spacing: 16) {
            Button("Analyze") { analyze(image: image) }
                .buttonStyle(.borderedProminent)
            Button("Clear") { clearAll() }
                .buttonStyle(.bordered)
        }
    }

    private func quickResultView(image: UIImage, quick: String) -> some View {
        VStack(spacing: 12) {
            ScrollView {
                Text(quick).padding(.horizontal)
            }
            .frame(maxHeight: 120)

            if savedEntryID != nil {
                HStack(spacing: 16) {
                    Button("Dream") { startDream() }
                        .buttonStyle(.borderedProminent)
                    Button("Clear") { clearAll() }
                        .buttonStyle(.bordered)
                }
                Text("Saved ✓").foregroundStyle(.green).font(.caption)
            } else {
                HStack(spacing: 16) {
                    Button("Save") { saveEntry(image: image, description: quick) }
                        .buttonStyle(.borderedProminent)
                    Button("Clear") { clearAll() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var dreamProgressView: some View {
        VStack(spacing: 12) {
            switch llmService.state {
            case .needsDownload, .idle:
                ProgressView("Preparing dream...")
            case .downloading(let p):
                VStack(spacing: 8) {
                    ProgressView(value: p).padding(.horizontal)
                    Text("Downloading model \(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
                }
            case .loading:
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading model...").font(.caption).foregroundStyle(.secondary)
                }
            case .ready:
                ProgressView("Dreaming...")
            case .error(let msg):
                Text(msg).foregroundStyle(.red).font(.caption)
            }
        }
    }

    private func dreamResultView(dream: String) -> some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dream").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(dream).padding(.horizontal)
                }
                .frame(maxHeight: 150)
            }
            Button("Clear") { clearAll() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Actions

    private func analyze(image: UIImage) {
        isAnalyzing = true
        errorMessage = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try self.quickVision.analyze(image: image)
                }.value
                quickDescription = result.formattedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    private func saveEntry(image: UIImage, description: String) {
        do {
            try memoryStore.save(image: image, description: description)
            savedEntryID = memoryStore.entries.last?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startDream() {
        isDreaming = true
        errorMessage = nil
        switch llmService.state {
        case .needsDownload:
            llmService.download()
        case .idle:
            llmService.loadModel()
        case .ready:
            runDreamInference()
        default:
            break
        }
    }

    private func runDreamInference() {
        guard let inference = llmService.inference,
              let quick = quickDescription else { return }
        let svc = DreamService(inference: inference)
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try svc.describe(quickDescription: quick)
                }.value
                if let entryID = savedEntryID {
                    try? memoryStore.updateDream(id: entryID, dreamDescription: result)
                }
                dreamDescription = result
                llmService.unloadModel()
            } catch {
                errorMessage = error.localizedDescription
            }
            isDreaming = false
        }
    }

    private func reset() {
        quickDescription = nil
        dreamDescription = nil
        errorMessage = nil
        photoItem = nil
        savedEntryID = nil
    }

    private func clearAll() {
        selectedImage = nil
        reset()
    }
}
