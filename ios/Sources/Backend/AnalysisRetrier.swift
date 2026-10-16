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
    /// True until a pass starts; set again when the app goes to the
    /// background. `scenePhase` also reports `.active` after a mere
    /// `.inactive` flip (notification shade, system sheets), which is not
    /// a new foreground.
    private var armed = true
    /// Bumped on every background. A pass belongs to the foreground it
    /// started in and stops once the generation moves on.
    private var generation = 0

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
        generation += 1
    }

    /// One pass per foreground, with at most one retry attempt per
    /// session. A trigger before the app has been backgrounded again is
    /// dropped, and a pass still running when the app backgrounds stops
    /// before its next session (its in-flight request finishes), so it
    /// cannot overlap the next foreground's pass.
    func runOnForeground(now: Date = Date()) async {
        guard armed else { return }
        armed = false
        let foreground = generation

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
            guard foreground == generation else { return }
            await attempt(sessionID, upstream: upstream, foreground: foreground)
        }
    }

    private func attempt(_ sessionID: String, upstream: [String: String], foreground: Int) async {
        do {
            // 404 (not uploaded yet, or forgotten by the server) → nil.
            guard let status = try await deps.status(sessionID),
                  RetryAnalysisPolicy.shouldRetry(segments: status.segments, upstream: upstream),
                  foreground == generation
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
