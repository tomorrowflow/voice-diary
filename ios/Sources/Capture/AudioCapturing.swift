import AVFoundation
import Foundation

/// The capture-engine operations the coordinators and the session bundle
/// consume. `AudioEngine` is the production conformance; tests inject a
/// fake so coordinator logic runs without a microphone or an audio session.
/// Hardware notification and route-change handling stay inside `AudioEngine`.
protocol AudioCapturing: Sendable {
    /// Arms the audio session ahead of `start` (idempotent).
    func prepareSession() async throws
    /// Starts writing a segment to `outputURL`. `streaming` receives each
    /// 16 kHz mono buffer on the audio thread when supplied.
    func start(
        outputURL: URL,
        streaming: (@Sendable (AVAudioPCMBuffer) -> Void)?
    ) async throws
    /// Finalises the open segment and returns its file.
    func stop() async throws -> URL?
    /// Tears the engine down after the last segment.
    func shutdown() async
    /// Third audio sink used by wake-word listening; nil clears it.
    func setWakeWordSink(_ sink: (@Sendable (AVAudioPCMBuffer) -> Void)?) async
    /// True when a system interruption cut the latest capture short. A new
    /// `start` clears it.
    var wasInterrupted: Bool { get async }
    /// Sample rate of the most recently started capture (0 when unknown).
    var lastSampleRate: Double { get async }
}

extension AudioCapturing {
    func start(outputURL: URL) async throws {
        try await start(outputURL: outputURL, streaming: nil)
    }
}

extension AudioEngine: AudioCapturing {}
