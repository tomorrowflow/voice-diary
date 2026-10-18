import AVFoundation
import Foundation
import Testing
import UIKit
@testable import VoiceDiary

// Share-staged diary audio is protected with the app-wide class instead of
// `.none`, and the temporary export is deleted when the share ends —
// completed, cancelled or failed — while the user's source audio stays put
// (SEC-3, #21). Runs on real files in a temp directory.

@Suite("Share staging protection and cleanup")
struct ShareStagingTests {
    private let payload = Data("not-really-aac-but-bytes".utf8)

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "vd-share-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSource(in dir: URL, name: String = "source.m4a") throws -> URL {
        let url = dir.appending(path: name)
        try payload.write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Protection class

    /// Records the (file, class) pairs a staging call asks for. The
    /// simulator ignores per-file protection, so reading the class back
    /// from disk can't tell `.none` from the real class there.
    private final class ProtectionRecorder: @unchecked Sendable {
        struct Call {
            let url: URL
            let protection: URLFileProtection
            /// Bytes on disk when the class was applied; `nil` if the file
            /// didn't exist yet.
            let sizeAtCall: Int?
        }

        private let lock = NSLock()
        private var calls: [Call] = []

        var setter: ShareStaging.ProtectionSetter {
            { [self] url, protection in
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
                lock.lock()
                calls.append(Call(url: url, protection: protection, sizeAtCall: size))
                lock.unlock()
            }
        }

        var recorded: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    @Test("the app-wide class is completeUntilFirstUserAuthentication")
    func appWideClass() {
        #expect(LocalStore.protectionClass == .completeUntilFirstUserAuthentication)
    }

    @Test("a staged copy is tagged with the app-wide class, never none")
    func stagedCopyIsProtected() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSource(in: dir)
        let recorder = ProtectionRecorder()

        let staged = try ShareStaging.stage(
            sourceURL: source, baseName: "voicediary-note-x", in: dir, protect: recorder.setter
        )

        #expect(recorder.recorded.count == 1)
        #expect(recorder.recorded.first?.url == staged)
        #expect(recorder.recorded.first?.protection == LocalStore.protectionClass)
        #expect(try Data(contentsOf: staged) == payload)
        #expect(staged.lastPathComponent == "voicediary-note-x.m4a")
        #expect(exists(source))
    }

    @Test("staging with the real setter keeps the copy readable")
    func stagedCopyWithRealSetter() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSource(in: dir)

        let staged = try ShareStaging.stage(sourceURL: source, baseName: "export", in: dir)

        #expect(try Data(contentsOf: staged) == payload)
        #expect(LocalStore.currentProtection(of: staged) != URLFileProtection.none)
    }

    @Test("a merged export (single-segment copy path) is tagged with the app-wide class")
    func mergedExportIsProtected() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSource(in: dir)
        let output = dir.appending(path: "merged.m4a")
        let recorder = ProtectionRecorder()

        try AudioMerger.copyOut(from: source, to: output, protect: recorder.setter)

        #expect(recorder.recorded.count == 1)
        #expect(recorder.recorded.first?.url == output)
        #expect(recorder.recorded.first?.protection == LocalStore.protectionClass)
        #expect(try Data(contentsOf: output) == payload)
        #expect(exists(source))
    }

    /// A short mono AAC `.m4a` the real merge path can decode.
    private func makeToneSegment(in dir: URL, name: String) throws -> URL {
        let url = dir.appending(path: name)
        let sampleRate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(sampleRate / 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = 0.3 * sin(Float(index) * 0.05)
        }
        // Scope so the writer finalises the m4a before it is read back.
        do {
            let writer = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                ]
            )
            try writer.write(from: buffer)
        }
        return url
    }

    @Test("the multi-segment scratch file is protected from creation and the export is tagged")
    func multiSegmentScratchIsProtected() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try makeToneSegment(in: dir, name: "a.m4a")
        let second = try makeToneSegment(in: dir, name: "b.m4a")
        let output = dir.appending(path: "merged.m4a")
        let scratch = dir.appending(path: "merged.scratch.m4a")
        let recorder = ProtectionRecorder()

        try await AudioMerger.merge(segments: [first, second], outputURL: output, protect: recorder.setter)

        let recorded = recorder.recorded
        // First call: the scratch, tagged while still empty — before any
        // diary audio is written into it.
        #expect(recorded.first?.url == scratch)
        #expect(recorded.first?.sizeAtCall == 0)
        #expect(recorded.allSatisfy { $0.protection == LocalStore.protectionClass })
        // Last call: the final export.
        #expect(recorded.last?.url == output)
        // The merge still produces a playable file and cleans its scratch.
        let merged = try AVAudioFile(forReading: output)
        #expect(merged.length > 0)
        #expect(!exists(scratch))
        #expect(exists(first) && exists(second))
    }

    @Test("mergedTempFile stages a readable copy in tmp and leaves the source")
    func mergedTempFileStagesInTmp() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSource(in: dir)
        let id = "2026-10-17T09:00:00+02:00-\(UUID().uuidString)"

        let staged = try await AudioMerger.mergedTempFile(for: id, segments: [source])
        defer { try? FileManager.default.removeItem(at: staged) }

        #expect(try Data(contentsOf: staged) == payload)
        #expect(LocalStore.currentProtection(of: staged) != URLFileProtection.none)
        #expect(staged.deletingLastPathComponent().standardizedFileURL
            == FileManager.default.temporaryDirectory.standardizedFileURL)
        #expect(exists(source))
    }

    // MARK: - Cleanup after the share

    private enum Outcome: CaseIterable {
        case completed, cancelled, failed
    }

    @Test("the temp export is removed after a completed, cancelled or failed share; source stays",
          arguments: Outcome.allCases)
    private func exportRemovedAfterShare(_ outcome: Outcome) throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSource(in: dir)
        let staged = try ShareStaging.stage(sourceURL: source, baseName: "export", in: dir)
        #expect(exists(staged))

        let handler = ShareStaging.discardingHandler(for: staged)
        switch outcome {
        case .completed:
            handler(.copyToPasteboard, true, nil, nil)
        case .cancelled:
            handler(nil, false, nil, nil)
        case .failed:
            handler(.mail, false, nil, NSError(domain: "share", code: 1))
        }

        #expect(!exists(staged))
        #expect(exists(source))
        #expect(try Data(contentsOf: source) == payload)
    }

    @Test("discard is idempotent and ignores nil or missing files")
    func discardIsIdempotent() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeSource(in: dir)
        let staged = try ShareStaging.stage(sourceURL: source, baseName: "export", in: dir)

        ShareStaging.discard(staged)
        ShareStaging.discard(staged)
        ShareStaging.discard(nil)

        #expect(!exists(staged))
        #expect(exists(source))
    }

    @Test("a failed merge leaves no export or scratch file behind")
    func failedMergeLeavesNothing() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two undecodable segments force the real merge path, which throws.
        let a = try makeSource(in: dir, name: "a.m4a")
        let b = try makeSource(in: dir, name: "b.m4a")
        let id = "failed-merge-\(UUID().uuidString)"
        let expected = FileManager.default.temporaryDirectory.appending(path: "voicediary-\(id).m4a")

        await #expect(throws: (any Error).self) {
            _ = try await AudioMerger.mergedTempFile(for: id, segments: [a, b])
        }

        #expect(!exists(expected))
        #expect(!exists(expected.deletingPathExtension().appendingPathExtension("scratch.m4a")))
        #expect(exists(a) && exists(b))
    }
}
