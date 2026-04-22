import Foundation
import BackgroundTasks

@Observable
@MainActor
final class DreamService {
    private(set) var isRunning = false
    private(set) var lastError: String?

    private let wikiStore: WikiStore
    private let log: DreamLog
    private let gemmaService: GemmaVisionService

    init(wikiStore: WikiStore, log: DreamLog, gemmaService: GemmaVisionService) {
        self.wikiStore = wikiStore
        self.log = log
        self.gemmaService = gemmaService
    }

    func dream(memoryStore: MemoryStore) async {
        guard !isRunning else { return }
        guard gemmaService.state == .ready, let engine = gemmaService.engine else {
            lastError = "Gemma model not loaded — open Capture tab and load the model first"
            return
        }

        isRunning = true
        lastError = nil
        log.clear()
        defer { isRunning = false }

        do {
            let captures = unprocessedCaptures(memoryStore: memoryStore)
            guard !captures.isEmpty else {
                await log.append("No new memories to process")
                return
            }

            let entropyPages = selectEntropyPages(limit: 2)
            for page in entropyPages {
                await log.append("Surfacing old memory: \(page)")
            }

            let agent = DreamAgent(engine: engine, wikiStore: wikiStore, log: log)
            try await agent.run(captures: captures, entropyPages: entropyPages, memoryStore: memoryStore)
            try wikiStore.markDreamed()
        } catch {
            lastError = error.localizedDescription
            await log.append("Error: \(error.localizedDescription)")
        }
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

    private func selectEntropyPages(limit: Int) -> [String] {
        let pages = wikiStore.oldestCachePages(limit: limit * 3)
        guard !pages.isEmpty else { return [] }
        return Array(pages.shuffled().prefix(limit))
    }
}
