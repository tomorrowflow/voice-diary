import AVFoundation
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import VoiceDiary

// Disk-full mapping for capture errors (UX-2). SPEC §15.2: a capture must
// never lose audio it already wrote, so the copy tells the user to free
// space rather than dumping a raw NSError.

@Suite("CaptureErrorMessage")
@MainActor
struct CaptureErrorMessageTests {
    private let cocoaFull = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
    private let posixFull = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    private let quota = NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))
    private let avFull = NSError(domain: AVFoundationErrorDomain, code: AVError.diskFull.rawValue)

    private let allContexts: [CaptureErrorMessage.Context] = [.start, .resume, .finishAudioSaved, .finish]

    @Test("recognises out-of-space errors in every shape")
    func recognisesOutOfSpace() {
        for error in [cocoaFull, posixFull, quota, avFull] {
            #expect(CaptureErrorMessage.isOutOfSpace(error), "\(error)")
        }
    }

    @Test("recognises out-of-space wrapped as an underlying error")
    func recognisesUnderlying() {
        let wrapped = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: posixFull]
        )
        #expect(CaptureErrorMessage.isOutOfSpace(wrapped))
    }

    @Test("other errors are not out-of-space")
    func rejectsOthers() {
        let others = [
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
            NSError(domain: AVFoundationErrorDomain, code: AVError.sessionNotRunning.rawValue),
            NSError(domain: "test", code: Int(ENOSPC)),
        ]
        for error in others {
            #expect(!CaptureErrorMessage.isOutOfSpace(error), "\(error)")
        }
    }

    @Test("other errors keep their raw description")
    func otherErrorsStayRaw() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        for context in allContexts {
            #expect(CaptureErrorMessage.message(for: error, context: context) == "\(error)")
        }
    }

    @Test("disk-full gets recovery copy, not the raw error")
    func diskFullCopy() {
        for context in allContexts {
            let text = CaptureErrorMessage.message(for: cocoaFull, context: context)
            #expect(text.contains("Not enough storage") || text.contains("Speicher"))
            #expect(!text.contains("NSCocoaErrorDomain"))
        }
    }

    @Test("audio-preservation claims only where audio is on disk")
    func preservationClaims() {
        let saved = CaptureErrorMessage.message(for: cocoaFull, context: .finishAudioSaved)
        let start = CaptureErrorMessage.message(for: cocoaFull, context: .start)
        let finish = CaptureErrorMessage.message(for: cocoaFull, context: .finish)
        #expect(saved != start && saved != finish)
        #expect(!start.lowercased().contains("saved"))
        #expect(!finish.lowercased().contains("saved"))
    }

    // Seam: when `metadata.json` can't be written because the disk is full,
    // the audio chunks next to it stay untouched (the coordinator then keeps
    // `sessionDir`), and the surfaced error is the recovery copy.
    @Test("metadata write hitting a full disk leaves audio intact")
    func metadataFailurePreservesAudio() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ux2-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appending(path: "audio.m4a")
        let bytes = Data(repeating: 0xAB, count: 4096)
        try bytes.write(to: audio)

        let note = VoiceNote(
            seed_id: "note-test",
            captured_at: Date(),
            duration_seconds: 3,
            language: "en",
            transcript: "hello",
            audio_file_url: audio
        )
        var thrown: (any Error)?
        do {
            try CaptureCoordinator.writeMetadata(note: note, into: dir) { _, _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
            }
        } catch {
            thrown = error
        }

        let error = try #require(thrown)
        #expect(CaptureErrorMessage.isOutOfSpace(error))
        #expect(CaptureErrorMessage.message(for: error, context: .finishAudioSaved)
            == CaptureErrorMessage.message(for: cocoaFull, context: .finishAudioSaved))
        #expect(try Data(contentsOf: audio) == bytes)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "metadata.json").path))
    }

    // Writes light/dark renders of the recovery copy for the ticket proof.
    // Opt-in: only runs while an (untracked) `ios/.render-screenshots`
    // marker file exists, then writes into `docs/screenshots/ux-2/`.
    @Test("renders recovery copy in light and dark")
    func renderScreenshots() throws {
        let iosDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: iosDir.appending(path: ".render-screenshots").path) else { return }
        let out = iosDir.deletingLastPathComponent().appending(path: "docs/screenshots/ux-2").path
        let message = CaptureErrorMessage.message(for: cocoaFull, context: .finishAudioSaved)
        for scheme in [ColorScheme.light, .dark] {
            let view = ZStack {
                Theme.color.bg.surface
                CaptureErrorText(message: message)
            }
            .frame(width: 393, height: 160)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let png = try #require(renderer.uiImage?.pngData())
            let name = "recovery-\(scheme == .dark ? "dark" : "light").png"
            try png.write(to: URL(fileURLWithPath: out).appending(path: name))
        }
    }
}
