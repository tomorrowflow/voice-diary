import Foundation

/// Runs `RetryAnalysisPolicy` over the locally known recent sessions once
/// per foreground transition (SPEC §10.6.1). Best effort and silent: any
/// failure is logged and the session stays `pending_analysis`, so the next
/// foreground tries again. The Verlauf "Processing" pill reflects progress.
public actor AnalysisRetrier {
    public static let shared = AnalysisRetrier()

    /// The IO a pass needs, injectable so tests drive it without a server.
    struct Dependencies: Sendable {
        var health: @Sendable () async throws -> [String: String]
        var recentSessionIDs: @Sendable (Date) async -> [String]
        var status: @Sendable (String) async throws -> ServerClient.SessionStatusResponse?
        var retry: @Sendable (String) async throws -> Void

        static let live = Dependencies(
            health: {
                struct Health: Decodable { let upstream: [String: String] }
                let data = try await ServerClient.shared.health()
                return try JSONDecoder().decode(Health.self, from: data).upstream
            },
            recentSessionIDs: { now in
                SessionHistoryStore.load().compactMap { item in
                    guard case .walkthrough(let entry) = item,
                          RetryAnalysisPolicy.isRecent(entry.capturedAt, now: now)
                    else { return nil }
                    return entry.sessionID
                }
            },
            status: { try await ServerClient.shared.sessionStatus(sessionID: $0) },
            retry: { _ = try await ServerClient.shared.retryAnalysis(sessionID: $0) }
        )
    }

    private let deps: Dependencies
    private var isRunning = false
    /// True until a pass starts; set again when the app goes to the
    /// background. `scenePhase` also reports `.active` after a mere
    /// `.inactive` flip (notification shade, system sheets), which is not
    /// a new foreground.
    private var armed = true

    init(deps: Dependencies = .live) {
        self.deps = deps
    }

    /// Fire-and-forget entry for the `scenePhase == .active` hook.
    public nonisolated func kick() {
        Task { await self.runOnForeground() }
    }

    /// Fire-and-forget entry for the `scenePhase == .background` hook:
    /// the next `.active` is a new foreground and may run a pass.
    public nonisolated func rearm() {
        Task { await self.markBackgrounded() }
    }

    func markBackgrounded() {
        armed = true
    }

    /// One pass per foreground, with at most one retry attempt per
    /// session. A trigger that arrives while a pass is running, or before
    /// the app has been backgrounded again, is dropped.
    func runOnForeground(now: Date = Date()) async {
        guard armed, !isRunning else { return }
        armed = false
        isRunning = true
        defer { isRunning = false }

        let upstream: [String: String]
        do {
            upstream = try await deps.health()
        } catch {
            Log.backend.debug("analysis retry skipped, health unavailable: \(String(describing: error), privacy: .public)")
            return
        }
        // Cheap early exit before any per-session request.
        guard RetryAnalysisPolicy.upstreamsHealthy(upstream) else { return }

        var attempted = Set<String>()
        for sessionID in await deps.recentSessionIDs(now) where attempted.insert(sessionID).inserted {
            await attempt(sessionID, upstream: upstream)
        }
    }

    private func attempt(_ sessionID: String, upstream: [String: String]) async {
        do {
            // 404 (not uploaded yet, or forgotten by the server) → nil.
            guard let status = try await deps.status(sessionID),
                  RetryAnalysisPolicy.shouldRetry(segments: status.segments, upstream: upstream)
            else { return }
            try await deps.retry(sessionID)
            Log.backend.info("analysis retry requested for \(sessionID, privacy: .public)")
        } catch where RetryAnalysisPolicy.isExpectedSkip(error) {
            return
        } catch {
            Log.backend.debug("analysis retry failed for \(sessionID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
