import SwiftUI

// Synthetic-session uploader for M3. Records 5 s of audio via AudioEngine,
// builds a single-segment free_reflection manifest, and posts it through
// SessionUploader (which handles backoff + persistence).

@MainActor
public struct DebugUploadView: View {
    @State private var engine = AudioEngine()
    @State private var statusText: String = "Bereit."
    @State private var isBusy: Bool = false
    @State private var lastResponse: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Nimmt 5 Sekunden Audio auf, baut ein Manifest und schickt es an POST /api/sessions.")
                        .font(Theme.font.callout)
                        .foregroundStyle(Theme.color.text.secondary)
                }

                Section {
                    Button {
                        Task { await runSyntheticUpload() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("Synthetik-Upload starten")
                        }
                    }
                    .disabled(isBusy)
                    .buttonStyle(.dsPrimary(size: .lg, fullWidth: true))
                }

                Section {
                    Text(statusText)
                        .font(Theme.font.monoCallout)
                        .foregroundStyle(Theme.color.text.primary)
                    if let lastResponse {
                        Text(lastResponse)
                            .font(Theme.font.monoCaption)
                            .foregroundStyle(Theme.color.text.secondary)
                    }
                } header: {
                    Text("Status")
                        .font(Theme.font.subheadline)
                        .foregroundStyle(Theme.color.text.secondary)
                }

                Section {
                    Button("Queue erneut versuchen") {
                        Task { await SessionUploader.shared.flush() }
                    }
                    .buttonStyle(.dsSecondary(fullWidth: true))
                    Button("Verwaiste Einträge entfernen") {
                        Task {
                            let n = await SessionUploader.shared.purgeOrphans()
                            statusText = n > 0 ? "Entfernt: \(n)" : "Keine verwaisten Einträge."
                        }
                    }
                    .buttonStyle(.dsGhost(fullWidth: true))
                    Button(role: .destructive) {
                        Task {
                            await SessionUploader.shared.clear()
                            statusText = "Queue geleert."
                            lastResponse = nil
                        }
                    } label: {
                        Text("Queue komplett löschen")
                    }
                    .buttonStyle(.dsDestructive(fullWidth: true))
                } header: {
                    Text("Queue")
                        .font(Theme.font.subheadline)
                        .foregroundStyle(Theme.color.text.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.color.bg.surface.ignoresSafeArea())
            .navigationTitle("Test-Upload")
        }
    }

    private func runSyntheticUpload() async {
        isBusy = true
        defer { isBusy = false }

        do {
            statusText = "Nehme 5 s auf …"
            let stagingRoot = try LocalStore.sessionsStagingDir()
            let sessionID = ISO8601DateFormatter().string(from: Date())
            let sessionDir = stagingRoot.appending(path: sanitize(sessionID), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: sessionDir.appending(path: "segments"),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sessionDir.appending(path: "raw"),
                                                    withIntermediateDirectories: true)

            let segmentURL = sessionDir.appending(path: "segments/s01.m4a")
            try await engine.start(outputURL: segmentURL)
            try await Task.sleep(nanoseconds: 5_000_000_000)
            _ = try await engine.stop()
            let actualSampleRate = await engine.lastSampleRate

            let rawURL = sessionDir.appending(path: "raw/session.m4a")
            try? FileManager.default.removeItem(at: rawURL)
            try FileManager.default.copyItem(at: segmentURL, to: rawURL)

            let manifest = Manifest(
                session_id: sessionID,
                date: todayString(),
                audio_codec: AudioCodec(
                    codec: "aac-lc",
                    sample_rate: Int(actualSampleRate.rounded()),
                    channels: 1,
                    bitrate: 64_000
                ),
                segments: [
                    .freeReflection(.init(
                        segment_id: "s01",
                        audio_file: "segments/s01.m4a",
                        captured_at: ISO8601DateFormatter().string(from: Date())
                    )),
                ],
                raw_session_audio: "raw/session.m4a",
                ai_prompts: [
                    AiPrompt(
                        at: ISO8601DateFormatter().string(from: Date()),
                        role: "synthetic_test",
                        text: "Test-Upload aus DebugUploadView."
                    )
                ]
            )

            let audioFiles: [String: URL] = [
                "segments/s01.m4a": segmentURL,
                "raw/session.m4a": rawURL,
            ]

            statusText = "Lade hoch …"
            do {
                let response = try await ServerClient.shared.uploadSession(
                    manifest: manifest, audioFiles: audioFiles
                )
                statusText = "OK — \(response.session_id)"
                lastResponse = response.segments.map {
                    "\($0.segment_id): \($0.status)" +
                    ($0.transcript_id.map { " (transcript \($0))" } ?? "")
                }.joined(separator: "\n")
            } catch {
                await SessionUploader.shared.enqueue(manifest: manifest, audioFiles: audioFiles)
                statusText = "Direkter Upload fehlgeschlagen — in der Queue."
                lastResponse = "\(error)"
            }
        } catch {
            statusText = "Fehler: \(error)"
        }
    }

    private func todayString() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: ":", with: "-")
         .replacingOccurrences(of: "+", with: "_")
    }
}
