import Foundation
import BackgroundTasks

@Observable
@MainActor
final class DreamService {
    private(set) var isRunning = false
    private(set) var lastError: String?
    private var _cancelled = false

    func cancel() { _cancelled = true }

    private let wikiStore: WikiStore
    private let log: DreamLog
    private let gemmaService: GemmaVisionService
    private let promptConfig: PromptConfig

    init(wikiStore: WikiStore, log: DreamLog, gemmaService: GemmaVisionService, promptConfig: PromptConfig) {
        self.wikiStore = wikiStore
        self.log = log
        self.gemmaService = gemmaService
        self.promptConfig = promptConfig
    }

    func dream(memoryStore: MemoryStore) async {
        guard !isRunning else { return }
        guard gemmaService.state == .ready, let engine = gemmaService.engine else {
            lastError = "Gemma model not loaded — open Capture tab and load the model first"
            return
        }

        isRunning = true
        _cancelled = false
        lastError = nil
        log.clear()
        defer { isRunning = false }

        do {
            let captures = unprocessedCaptures(memoryStore: memoryStore)
            guard !captures.isEmpty else {
                log.beginPhase("Nothing to process")
                log.beginStep("Check captures")
                log.logInfo("No captures since last dream")
                log.endStep(success: true)
                log.endPhase(success: true)
                return
            }

            var agent = DreamAgent(engine: engine, wikiStore: wikiStore, log: log, promptConfig: promptConfig)
            agent.shouldCancel = { [weak self] in self?._cancelled ?? false }
            try await agent.run(captures: captures, entropyPages: [], memoryStore: memoryStore)
        } catch {
            lastError = error.localizedDescription
            log.logError(error.localizedDescription)
        }
        log.save()
    }

    func reflect() async {
        guard !isRunning else { return }
        guard gemmaService.state == .ready, let engine = gemmaService.engine else {
            lastError = "Gemma model not loaded — open Capture tab and load the model first"
            return
        }
        isRunning = true
        _cancelled = false
        lastError = nil
        log.clear()
        defer { isRunning = false }
        do {
            var agent = DreamAgent(engine: engine, wikiStore: wikiStore, log: log, promptConfig: promptConfig)
            agent.shouldCancel = { [weak self] in self?._cancelled ?? false }
            try await agent.runReflectionPass()
        } catch {
            lastError = error.localizedDescription
            log.logError(error.localizedDescription)
        }
        log.save()
    }

    func consolidate() async {
        guard !isRunning else { return }
        guard gemmaService.state == .ready, let engine = gemmaService.engine else {
            lastError = "Gemma model not loaded — open Capture tab and load the model first"
            return
        }
        isRunning = true
        _cancelled = false
        lastError = nil
        log.clear()
        defer { isRunning = false }
        do {
            var agent = DreamAgent(engine: engine, wikiStore: wikiStore, log: log, promptConfig: promptConfig)
            agent.shouldCancel = { [weak self] in self?._cancelled ?? false }
            try await agent.runConsolidationPass()
        } catch {
            lastError = error.localizedDescription
            log.logError(error.localizedDescription)
        }
        log.save()
    }

    // MARK: - BGProcessingTask

    static let bgTaskIdentifier = "com.ispy.dream"

    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgTaskIdentifier, using: nil
        ) { [weak self] task in
            guard let self, let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                if self.gemmaService.state != .ready {
                    await self.gemmaService.start()
                }
                let memoryStore = MemoryStore()
                await self.dream(memoryStore: memoryStore)
                task.setTaskCompleted(success: self.lastError == nil)
                self.scheduleNextDream()
            }
            task.expirationHandler = { task.setTaskCompleted(success: false) }
        }
    }

    func scheduleNextDream() {
        let request = BGProcessingTaskRequest(identifier: Self.bgTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true
        request.earliestBeginDate = Calendar.current.date(byAdding: .hour, value: 22, to: Date())
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Private

    private func unprocessedCaptures(memoryStore: MemoryStore) -> [MemoryEntry] {
        let cursor = wikiStore.lastDreamed ?? .distantPast
        return memoryStore.entries.filter { $0.timestamp > cursor }
    }

}
