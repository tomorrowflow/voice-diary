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
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        Task { await runSyntheticUpload() }
                    } label: {
                        Label("Synthetik-Upload starten", systemImage: "arrow.up.circle.fill")
                    }
                    .disabled(isBusy)
                }

                Section("Status") {
                    Text(statusText)
                        .font(.callout.monospaced())
                    if let lastResponse {
                        Text(lastResponse)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Queue erneut versuchen") {
                        Task { await SessionUploader.shared.flush() }
                    }
                }
            }
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

            // Reuse the single segment as the "raw session audio" too —
            // the server accepts a path string here, and a real session
            // would be the full unedited capture.
            let rawURL = sessionDir.appending(path: "raw/session.m4a")
            try? FileManager.default.removeItem(at: rawURL)
            try FileManager.default.copyItem(at: segmentURL, to: rawURL)

            let manifest = Manifest(
                session_id: sessionID,
                date: todayString(),
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
                // Direct upload failed — fall back to the persistent queue.
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
