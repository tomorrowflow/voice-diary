import Foundation
import Testing
@testable import VoiceDiary

// IOS-A14 (#10): `CaptureCoordinator` runs against a fake `AudioCapturing`
// engine, so start / pause / resume / stop ordering, a failed start and the
// interruption latch are tested without a microphone. Notes go to a temp
// directory and transcription, the start tone and the completion
// notification are stubbed. This proves the coordinator's reaction to the
// engine's answers, not real call / Siri interruptions or Bluetooth routes.

@MainActor
private final class EffectsProbe {
    private(set) var cues = 0
    private(set) var announcements = 0
    private(set) var transcribed: [String] = []

    func effects(notesIn dir: URL) -> CaptureCoordinator.Effects {
        var effects = CaptureCoordinator.Effects()
        effects.notesDirectory = { dir }
        effects.transcribe = { [self] url in
            transcribed.append(url.lastPathComponent)
            return ParakeetManager.Transcript(text: "hello", language: "en", confidence: 1)
        }
        effects.playStartCue = { [self] in cues += 1 }
        effects.announceCompletion = { [self] _, _ in announcements += 1 }
        return effects
    }
}

@MainActor
@Suite("CaptureCoordinator with a fake engine")
struct CaptureCoordinatorSeamTests {
    private let probe = EffectsProbe()
    private let engine = FakeAudioEngine()
    private let notesDir: URL
    private let coordinator: CaptureCoordinator

    init() throws {
        notesDir = FileManager.default.temporaryDirectory
            .appending(path: "vd-capture-seam-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        coordinator = CaptureCoordinator(engine: engine, effects: probe.effects(notesIn: notesDir))
    }

    @Test("start arms the session, then starts the first chunk")
    func startPreparesThenStarts() async {
        await coordinator.start()

        #expect(await engine.calls == ["prepareSession", "start:audio.m4a"])
        #expect(coordinator.isRecording)
        #expect(coordinator.lastError == nil)
        #expect(probe.cues == 1)
        await coordinator.stop()
    }

    @Test("a failed engine start leaves no recording and reports the error")
    func failedStart() async {
        await engine.failStarts()

        await coordinator.start()

        #expect(await engine.calls == ["prepareSession", "start:audio.m4a"])
        #expect(!coordinator.isRecording)
        #expect(coordinator.startedAt == nil)
        #expect(coordinator.lastError != nil)
        #expect(probe.cues == 0)
        #expect(probe.announcements == 0)
    }

    @Test("stop finalises the chunk before it shuts the engine down")
    func stopOrdering() async {
        await coordinator.start()

        await coordinator.stop()

        #expect(await engine.calls == ["prepareSession", "start:audio.m4a", "stop", "shutdown"])
        #expect(!coordinator.isRecording)
        #expect(coordinator.lastNote?.transcript == "hello")
        #expect(probe.transcribed == ["audio.m4a"])
        #expect(probe.announcements == 1)
    }

    @Test("resume starts the next chunk file after re-arming the session")
    func pauseResumeOrdering() async {
        await coordinator.start()

        await coordinator.pause()
        await coordinator.resume()
        await coordinator.stop()

        #expect(await engine.calls == [
            "prepareSession", "start:audio.m4a",
            "stop",
            "prepareSession", "start:audio_002.m4a",
            "stop", "shutdown",
        ])
        #expect(coordinator.lastNote?.chunks?.map(\.filename) == ["audio.m4a", "audio_002.m4a"])
    }

    @Test("an interruption seen at pause stays latched through resume and stop")
    func interruptionLatchesAcrossResume() async {
        await coordinator.start()
        await engine.interrupt()

        await coordinator.pause()
        #expect(coordinator.recordingWasInterrupted)

        // The fake clears its own flag on start, like AudioEngine does.
        await coordinator.resume()
        #expect(!(await engine.wasInterrupted))
        #expect(coordinator.recordingWasInterrupted)

        await coordinator.stop()
        #expect(coordinator.recordingWasInterrupted)
    }

    @Test("an interruption seen at stop is latched, and the next start clears it")
    func interruptionLatchesAtStopAndClearsOnStart() async {
        await coordinator.start()
        await engine.interrupt()

        await coordinator.stop()
        #expect(coordinator.recordingWasInterrupted)

        await coordinator.start()
        #expect(!coordinator.recordingWasInterrupted)
        await coordinator.stop()
    }

    @Test("stop keeps the audio when an interruption already closed the writer")
    func stopToleratesNotRunningAfterInterruption() async {
        await coordinator.start()
        await engine.interrupt()
        await engine.failStops(with: AudioEngine.EngineError.notRunning)

        await coordinator.stop()

        #expect(await engine.calls.suffix(2) == ["stop", "shutdown"])
        #expect(coordinator.lastError == nil)
        #expect(coordinator.lastNote != nil)
        #expect(coordinator.recordingWasInterrupted)
    }

    @Test("stop without an interruption reports a failing engine stop")
    func stopReportsEngineFailure() async {
        await coordinator.start()
        await engine.failStops(with: AudioEngine.EngineError.sessionConfigFailed("x"))

        await coordinator.stop()

        #expect(coordinator.lastError != nil)
        #expect(coordinator.lastNote == nil)
        #expect(!coordinator.isRecording)
        #expect(probe.announcements == 0)
    }

    @Test("a failed resume stays paused and reports the error")
    func failedResume() async {
        await coordinator.start()
        await coordinator.pause()
        await engine.failStarts()

        await coordinator.resume()

        #expect(coordinator.isPaused)
        #expect(coordinator.lastError != nil)
        await coordinator.stop()
    }
}
