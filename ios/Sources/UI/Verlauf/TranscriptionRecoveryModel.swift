import Foundation
import SwiftUI

/// The Verlauf detail screen's side of transcription recovery (FTR-05,
/// ADR 0005/0007): owns the `TranscriptionRecoveryRunner` of ticket 04, shows
/// its state and the last-known Whisper health, and turns the screen's
/// lifecycle and the user's tap into runner calls. It decides nothing itself:
/// the action for a row comes from `TranscriptionRecoveryPolicy` through
/// `State.action(for:whisper:)`.
///
/// Nothing here starts an attempt except `recover(segmentID:)`, which only the
/// button calls. Appearing, returning to the foreground and Whisper turning
/// healthy only read the status and `/health`.
@MainActor
@Observable
final class TranscriptionRecoveryModel {
    private(set) var state = TranscriptionRecoveryRunner.State()
    /// Last-known `/health`; `.unknown` until the first read and whenever a
    /// read fails, which counts as not ok.
    private(set) var whisper: WhisperHealth = .unknown
    /// The first status read has been asked for. Before it the rows show no
    /// server status, after it a missing one reads "Unknown".
    private(set) var statusRequested = false

    @ObservationIgnored private let readHealth: @Sendable () async -> Data?
    @ObservationIgnored private let updates: AsyncStream<TranscriptionRecoveryRunner.State>.Continuation
    @ObservationIgnored private var updateStream: AsyncStream<TranscriptionRecoveryRunner.State>?
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var lifecycle: Task<Void, Never>?
    @ObservationIgnored private let runner: TranscriptionRecoveryRunner

    init(
        sessionID: String,
        deps: TranscriptionRecoveryRunner.Dependencies = .live,
        readHealth: @escaping @Sendable () async -> Data? = { try? await ServerClient.shared.health() }
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptionRecoveryRunner.State.self)
        self.readHealth = readHealth
        updates = continuation
        updateStream = stream
        runner = TranscriptionRecoveryRunner(
            sessionID: sessionID, deps: deps, onChange: { continuation.yield($0) })
    }

    deinit {
        updates.finish()
        consumer?.cancel()
        lifecycle?.cancel()
    }

    /// The screen appeared or the app came back to the foreground (`true`),
    /// or the screen was left or the app went to the background (`false`).
    /// Calls run one after the other so a quick leave cannot overtake the
    /// appearance before it.
    func setVisible(_ visible: Bool) {
        startConsuming()
        if visible { statusRequested = true }
        let previous = lifecycle
        let runner = runner
        lifecycle = Task { [weak self] in
            await previous?.value
            if visible {
                // Health and status are independent reads; a slow one must
                // not hold the other back.
                async let health: Void? = self?.refreshHealth()
                await runner.screenAppeared()
                await health
            } else {
                await runner.screenLeft()
            }
        }
    }

    /// One explicit tap on "Erneut transkribieren".
    func recover(segmentID: String) {
        let runner = runner
        Task { await runner.start(segmentID: segmentID) }
    }

    func action(for segmentID: String) -> TranscriptionRecoveryAction {
        state.action(for: segmentID, whisper: whisper)
    }

    private func refreshHealth() async {
        whisper = WhisperHealth(healthData: await readHealth())
    }

    /// Applies runner states in the order the runner published them. An
    /// attempt that ended has changed what Whisper can do, so health is read
    /// again then: the button follows what Whisper is now, not what it was
    /// when the screen appeared.
    private func startConsuming() {
        guard let stream = updateStream else { return }
        updateStream = nil
        consumer = Task { [weak self] in
            for await next in stream {
                guard let self else { return }
                let attemptEnded = self.state.attemptSegmentID != nil && next.attemptSegmentID == nil
                self.state = next
                if attemptEnded { await self.refreshHealth() }
            }
        }
    }
}
