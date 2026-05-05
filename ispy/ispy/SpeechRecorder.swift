import Foundation
import Speech
import AVFoundation

@Observable
@MainActor
final class SpeechRecorder {
    private(set) var transcript = ""
    private(set) var isRecording = false
    private(set) var error: String?

    private let recognizer = SFSpeechRecognizer(locale: .current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    func start() {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.error = "Speech recognition not authorized"
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.error = "Microphone access denied"
                            return
                        }
                        self.beginRecording()
                    }
                }
            }
        }
    }

    @discardableResult
    func stop() -> String {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        isRecording = false
        return transcript
    }

    private func beginRecording() {
        guard !isRecording else { return }
        transcript = ""
        error = nil

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            self.error = error.localizedDescription
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        self.request = req

        let node = audioEngine.inputNode
        let fmt = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.request?.append(buf)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            self.error = error.localizedDescription
            return
        }

        isRecording = true
        task = recognizer?.recognitionTask(with: req) { [weak self] result, err in
            Task { @MainActor in
                if let result { self?.transcript = result.bestTranscription.formattedString }
                if err != nil || result?.isFinal == true { self?.isRecording = false }
            }
        }
    }
}
