import AVFoundation
import Foundation
import Observation

/// One-shot WAV recorder for Voxtral voice references. Records 24 kHz
/// mono 16-bit PCM (matches Voxtral's output format), max 15 s, with
/// audio-level metering for a UI VU display.
///
/// Owns its own `AVAudioRecorder` instance — separate from the
/// walkthrough's `AudioEngine` so a Settings-screen recording can't
/// interfere with an in-flight walkthrough session. The recorder is
/// only intended to be opened from Settings (not reachable mid-
/// walkthrough), so no cross-session arbitration is needed.

@MainActor
@Observable
public final class VoiceReferenceRecorder: NSObject, AVAudioRecorderDelegate {
    public enum RecorderError: Error, CustomStringConvertible {
        case permissionDenied
        case sessionConfigFailed(String)
        case recorderInitFailed(String)
        case notRecording

        public var description: String {
            switch self {
            case .permissionDenied:           return "Mikrofon-Zugriff nicht erlaubt."
            case .sessionConfigFailed(let s): return "Audio-Session: \(s)"
            case .recorderInitFailed(let s):  return "Recorder-Init: \(s)"
            case .notRecording:               return "Keine laufende Aufnahme."
            }
        }
    }

    /// Hard upper bound. Past this we auto-stop so the file stays
    /// under the server's 10 MB ceiling and the UI never gets stuck
    /// in a runaway recording.
    public static let maxDurationSeconds: TimeInterval = 15

    /// Sample rate matches Voxtral's output (24 kHz). The cloning
    /// model is robust to other rates, but matching avoids any
    /// resampling round-trip on the server side.
    public static let sampleRate: Double = 24_000

    /// True while a recorder is active (between `start()` and
    /// `stop()`/`cancel()`).
    public private(set) var isRecording: Bool = false
    /// Seconds elapsed since recording began. Updated ~10× per second.
    public private(set) var elapsed: TimeInterval = 0
    /// Normalised 0…1 average power for a VU meter. 0 = silence,
    /// 1 = clipping. Updated ~10× per second.
    public private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meteringTimer: Timer?
    private var startedAt: Date?

    public override init() {
        super.init()
    }

    // MARK: - Public surface

    public func start() async throws {
        guard !isRecording else { return }
        guard await Self.requestPermission() else {
            throw RecorderError.permissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: [])
        } catch {
            throw RecorderError.sessionConfigFailed(error.localizedDescription)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxtral-ref-\(UUID().uuidString.prefix(8)).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            throw RecorderError.recorderInitFailed(error.localizedDescription)
        }
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        recorder.record(forDuration: Self.maxDurationSeconds)

        self.recorder = recorder
        self.recordingURL = url
        self.isRecording = true
        self.elapsed = 0
        self.level = 0
        self.startedAt = Date()
        startMetering()
    }

    /// Stop recording and return the WAV file URL. Caller owns the
    /// file from here — it's the caller's responsibility to delete it
    /// after upload or discard.
    public func stop() throws -> URL {
        guard isRecording, let recorder, let url = recordingURL else {
            throw RecorderError.notRecording
        }
        stopMetering()
        recorder.stop()
        isRecording = false
        return url
    }

    public func cancel() {
        stopMetering()
        recorder?.stop()
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        recordingURL = nil
        isRecording = false
        elapsed = 0
        level = 0
    }

    // MARK: - AVAudioRecorderDelegate

    nonisolated public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully: Bool) {
        // Hit when AVAudioRecorder's own forDuration timer fires
        // (i.e. we hit the 15 s cap). Flip state on the main actor.
        Task { @MainActor in
            self.stopMetering()
            self.isRecording = false
        }
    }

    // MARK: - Internals

    private func startMetering() {
        meteringTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                // averagePower returns dBFS in roughly [-160, 0]. Map
                // to a normalised 0…1 power suitable for a UI bar;
                // -50 dBFS reads as ~0.2 (typical room noise) and 0
                // dBFS reads as 1.0 (clipping).
                let db = recorder.averagePower(forChannel: 0)
                let normalised = max(0, min(1, (db + 50) / 50))
                self.level = normalised
                if let started = self.startedAt {
                    self.elapsed = Date().timeIntervalSince(started)
                }
            }
        }
        meteringTimer = timer
    }

    private func stopMetering() {
        meteringTimer?.invalidate()
        meteringTimer = nil
    }

    // MARK: - Permission helper

    private static func requestPermission() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }
}
