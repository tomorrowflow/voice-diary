import ActivityKit
import AVFoundation
import Foundation
import SwiftUI
import UIKit

// Single source of truth for "is a drive-by recording in progress?"
//
// The widget extension and the App Intent both need to observe and mutate
// this state. We use:
//   * `UserDefaults(suiteName: AppGroup.identifier)` for cross-process
//     persistence so the widget timeline can read it.
//   * `ActivityKit.Activity` for a Live Activity that the lock-screen
//     widget surfaces while a capture is running.
//
// The coordinator is `@MainActor`-isolated; the underlying `AudioEngine`
// is itself an actor so its work happens off the main thread regardless.
//
// `AppGroup` and `CaptureActivityAttributes` live in `Sources/Shared/`
// because they're consumed by both this target and the widget extension.

@MainActor
@Observable
public final class CaptureCoordinator {
    public static let shared = CaptureCoordinator()

    public private(set) var isRecording: Bool = false
    public private(set) var startedAt: Date?
    public private(set) var elapsedSeconds: Int = 0
    public private(set) var statusLine: String = ""
    public private(set) var lastSeed: DriveBySeed?
    public private(set) var lastError: String?

    private let engine = AudioEngine()
    private var timer: Timer?
    private var liveActivity: Any?  // Activity<CaptureActivityAttributes> when iOS supports it

    public init() {
        // Hydrate from any leftover state in shared defaults (e.g. if a
        // crash left isRecording=true).
        if let defaults = UserDefaults(suiteName: AppGroup.identifier),
           defaults.bool(forKey: AppGroup.recordingActiveKey) {
            // Don't trust the previous run's "is recording"; reset it.
            defaults.set(false, forKey: AppGroup.recordingActiveKey)
        }
    }

    // --- toggle --------------------------------------------------------

    /// Idempotent toggle used by the App Intent. Returns the new state.
    @discardableResult
    public func toggle() async -> Bool {
        if isRecording { await stop() } else { await start() }
        return isRecording
    }

    public func start() async {
        guard !isRecording else { return }
        lastError = nil
        statusLine = ""
        do {
            let dir = try LocalStore.driveBySeedsDir()
                .appending(path: ISO8601DateFormatter().string(from: Date()),
                           directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let audio = dir.appending(path: "audio.m4a")
            try await engine.start(outputURL: audio)
            let now = Date()
            startedAt = now
            isRecording = true
            elapsedSeconds = 0
            startTimer()
            persistRecordingState(active: true, startedAt: now)
            startLiveActivity(at: now)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            lastError = "\(error)"
            persistRecordingState(active: false, startedAt: nil)
        }
    }

    public func stop() async {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        statusLine = "Transkribiere …"
        do {
            guard let url = try await engine.stop(), let started = startedAt else {
                isRecording = false
                statusLine = ""
                persistRecordingState(active: false, startedAt: nil)
                return
            }
            let duration = Date().timeIntervalSince(started)
            isRecording = false
            startedAt = nil
            persistRecordingState(active: false, startedAt: nil)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

            var transcript: ParakeetManager.Transcript?
            do {
                transcript = try await ParakeetManager.shared.transcribe(audioURL: url)
            } catch {
                Log.audio.warning(
                    "Parakeet transcript skipped: \(String(describing: error), privacy: .public)"
                )
            }

            let seed = DriveBySeed(
                seed_id: "seed-" + ISO8601DateFormatter().string(from: started),
                captured_at: started,
                duration_seconds: duration,
                language: transcript?.language ?? "de",
                transcript: transcript?.text ?? "",
                audio_file_url: url
            )
            try writeMetadata(seed: seed, alongside: url)
            lastSeed = seed
            persistLastSeed(seed)
            statusLine = transcript == nil
                ? "Aufnahme gespeichert. Transkript folgt beim Server-Upload."
                : "Aufnahme + Transkript gespeichert."
            await endLiveActivity()
            await CaptureNotifications.shared.fireCaptureComplete(
                duration: duration,
                transcriptPreview: seed.transcript.isEmpty ? nil : seed.transcript
            )
        } catch {
            lastError = "\(error)"
            statusLine = ""
            isRecording = false
            persistRecordingState(active: false, startedAt: nil)
            await endLiveActivity()
        }
    }

    // --- private helpers ----------------------------------------------

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsedSeconds += 1
                self.updateLiveActivity(elapsed: self.elapsedSeconds)
            }
        }
    }

    private func writeMetadata(seed: DriveBySeed, alongside audio: URL) throws {
        let json = audio.deletingLastPathComponent().appending(path: "metadata.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(seed)
        try data.write(to: json, options: [.atomic, .completeFileProtection])
    }

    private func persistRecordingState(active: Bool, startedAt: Date?) {
        guard let defaults = UserDefaults(suiteName: AppGroup.identifier) else { return }
        defaults.set(active, forKey: AppGroup.recordingActiveKey)
        if let startedAt {
            defaults.set(startedAt.timeIntervalSince1970,
                         forKey: AppGroup.recordingStartedAtKey)
        } else {
            defaults.removeObject(forKey: AppGroup.recordingStartedAtKey)
        }
    }

    private func persistLastSeed(_ seed: DriveBySeed) {
        guard let defaults = UserDefaults(suiteName: AppGroup.identifier) else { return }
        defaults.set(seed.transcript, forKey: AppGroup.lastSeedTranscriptKey)
        defaults.set(seed.duration_seconds, forKey: AppGroup.lastSeedDurationKey)
    }

    // --- Live Activity --------------------------------------------------

    private func startLiveActivity(at start: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = CaptureActivityAttributes()
        let state = CaptureActivityAttributes.ContentState(
            startedAt: start,
            elapsedSeconds: 0
        )
        do {
            let activity = try Activity.request(
                attributes: attrs,
                content: .init(state: state, staleDate: nil)
            )
            self.liveActivity = activity
        } catch {
            Log.audio.warning("Live Activity start failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func updateLiveActivity(elapsed: Int) {
        guard let activity = liveActivity as? Activity<CaptureActivityAttributes>,
              let started = startedAt else { return }
        let state = CaptureActivityAttributes.ContentState(
            startedAt: started,
            elapsedSeconds: elapsed
        )
        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    private func endLiveActivity() async {
        guard let activity = liveActivity as? Activity<CaptureActivityAttributes> else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        liveActivity = nil
    }
}
