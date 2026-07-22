import Foundation

/// Pure orchestration for resumable chunked migrations. Chunk analysis never publishes dashboard caches;
/// one final typed refresh succeeds before the completion marker is committed.
@MainActor
enum HistoricalMigrationDriver {
    enum Outcome: Equatable {
        case alreadyCompleted
        case completed
        case paused
        case cancelled
        case chunkFailed(offset: Int, message: String)
        case finalRefreshFailed
    }

    static func run(
        historyDays: Int,
        chunkDays: Int,
        isCompleted: () -> Bool,
        loadOffset: () -> Int,
        saveOffset: (Int) -> Void,
        markCompleted: () -> Void,
        shouldPause: () -> Bool,
        analyzeChunk: (_ days: Int, _ offset: Int) async throws -> Void,
        finalRefresh: () async -> Bool,
        interChunkDelay: Duration = .milliseconds(100),
        progress: (_ completedDays: Int, _ totalDays: Int) -> Void = { _, _ in }
    ) async -> Outcome {
        guard !isCompleted() else { return .alreadyCompleted }
        let total = max(0, historyDays)
        let size = max(1, chunkDays)

        while true {
            if Task.isCancelled { return .cancelled }
            if shouldPause() { return .paused }

            let offset = max(0, loadOffset())
            if offset >= total {
                guard await finalRefresh() else { return .finalRefreshFailed }
                markCompleted()
                progress(total, total)
                return .completed
            }

            let chunk = min(size, total - offset)
            do {
                try await analyzeChunk(chunk, offset)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .chunkFailed(offset: offset, message: String(describing: error))
            }

            if Task.isCancelled { return .cancelled }
            if shouldPause() { return .paused }

            let next = offset + chunk
            saveOffset(next)
            progress(next, total)
            await Task.yield()
            do {
                if interChunkDelay > .zero { try await Task.sleep(for: interChunkDelay) }
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .chunkFailed(offset: next, message: String(describing: error))
            }
        }
    }
}
