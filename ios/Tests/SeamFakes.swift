import AVFoundation
import Foundation
@testable import VoiceDiary

// Fakes for the `AudioCapturing` and `SessionTransport` seams. Neither opens
// a microphone, makes an HTTP request or reads a Keychain credential.

/// A capture engine that records every call in order. Like `AudioEngine`, a
/// new `start` clears the interrupted flag.
actor FakeAudioEngine: AudioCapturing {
    struct StartFailed: Error {}

    private(set) var calls: [String] = []
    private var interrupted = false
    private var startError: (any Error)?
    private var stopError: (any Error)?
    private var wakeSink: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func failStarts(with error: any Error = StartFailed()) { startError = error }
    func allowStarts() { startError = nil }
    func failStops(with error: any Error) { stopError = error }
    /// What a call / Siri / alarm interruption does to the engine's flag.
    func interrupt() { interrupted = true }
    var hasWakeWordSink: Bool { wakeSink != nil }

    func prepareSession() async throws {
        calls.append("prepareSession")
    }

    func start(
        outputURL: URL,
        streaming: (@Sendable (AVAudioPCMBuffer) -> Void)?
    ) async throws {
        calls.append("start:\(outputURL.lastPathComponent)")
        if let startError { throw startError }
        interrupted = false
        try Data("audio".utf8).write(to: outputURL)
    }

    func stop() async throws -> URL? {
        calls.append("stop")
        if let stopError { throw stopError }
        return nil
    }

    func shutdown() async {
        calls.append("shutdown")
    }

    func setWakeWordSink(_ sink: (@Sendable (AVAudioPCMBuffer) -> Void)?) async {
        wakeSink = sink
    }

    var wasInterrupted: Bool { interrupted }
    var lastSampleRate: Double { 44_100 }
}

/// An ordered log that `@Sendable` stubs can append to.
actor CallLog {
    private(set) var items: [String] = []

    func add(_ item: String) { items.append(item) }
}

/// Polls `condition` every few milliseconds until it holds or `cap` passes.
/// For work a coordinator starts in an unawaited `Task`.
@MainActor
func eventually(
    within cap: Duration = .seconds(1),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + cap
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A server transport answering from canned results and recording requests.
actor FakeTransport: SessionTransport {
    struct Unreachable: Error {}

    private(set) var calendarDates: [String] = []
    private(set) var recordedRanges: [String] = []
    private(set) var uploadedSessionIDs: [String] = []
    private(set) var healthCalls = 0

    private var calendarResult: Result<Data, any Error> = .failure(Unreachable())
    private var datesResult: Result<[String], any Error> = .failure(Unreachable())
    private var healthResult: Result<Data, any Error> = .failure(Unreachable())
    private var uploadResult: Result<SessionAccepted, any Error> = .failure(Unreachable())

    func stubCalendar(_ result: Result<Data, any Error>) { calendarResult = result }
    func stubDates(_ result: Result<[String], any Error>) { datesResult = result }
    func stubHealth(_ result: Result<Data, any Error>) { healthResult = result }
    func stubUpload(_ result: Result<SessionAccepted, any Error>) { uploadResult = result }

    func health() async throws -> Data {
        healthCalls += 1
        return try healthResult.get()
    }

    func todayCalendar(date: String, rsvpFilter: String) async throws -> Data {
        calendarDates.append("\(date)|\(rsvpFilter)")
        return try calendarResult.get()
    }

    func recordedDates(from: String?, to: String?) async throws -> [String] {
        recordedRanges.append("\(from ?? "nil")...\(to ?? "nil")")
        return try datesResult.get()
    }

    func uploadSession(
        manifest: Manifest,
        audioFiles: [String: URL]
    ) async throws -> SessionAccepted {
        uploadedSessionIDs.append(manifest.session_id)
        return try uploadResult.get()
    }
}
