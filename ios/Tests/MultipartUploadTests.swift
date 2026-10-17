import Foundation
import Testing
@testable import VoiceDiary

// The session upload streams its multipart body from a temporary file
// (IOS-A3, #3). Covers the exact form framing written by `MultipartBodyFile`
// and that `ServerClient.sendMultipart` removes the temp body on success,
// upload failure and a missing audio file. The upload runs through a
// `URLProtocol` stub, so no server or Keychain is involved.

/// Answers every request with a canned response (or error) and records the
/// streamed body plus the files sitting in `watchedDirectory` at that moment.
final class MultipartStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var failure: Error?
    nonisolated(unsafe) static var watchedDirectory: URL?
    nonisolated(unsafe) static var receivedBody = Data()
    nonisolated(unsafe) static var filesDuringUpload: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.receivedBody = Self.readBody(of: request)
        if let dir = Self.watchedDirectory {
            Self.filesDuringUpload = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        }
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(of request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

@Suite("Multipart session upload", .serialized)
struct MultipartUploadTests {
    private let boundary = "vd-TEST-BOUNDARY"

    private let manifest = Manifest(
        session_id: "2026-04-27T19:30:00+02:00",
        date: "2026-04-27",
        segments: [
            .freeReflection(.init(
                segment_id: "s01",
                audio_file: "segments/s01.m4a",
                captured_at: "2026-04-27T19:30:00+02:00"
            )),
        ]
    )

    private func makeDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "vd-multipart-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func contents(of dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
    }

    /// Bytes that repeat every 251, so a dropped or duplicated chunk shows.
    private func audioBytes(count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    private func expectedBody(audio: [(field: String, url: URL)]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var expected = Data()
        expected.append(Data("--\(boundary)\r\n".utf8))
        expected.append(Data(
            "Content-Disposition: form-data; name=\"manifest\"; filename=\"manifest.json\"\r\n".utf8
        ))
        expected.append(Data("Content-Type: application/json\r\n\r\n".utf8))
        expected.append(try encoder.encode(manifest))
        expected.append(Data("\r\n".utf8))
        for (field, url) in audio {
            expected.append(Data("--\(boundary)\r\n".utf8))
            expected.append(Data(
                "Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(url.lastPathComponent)\"\r\n".utf8
            ))
            // What `UTType(filenameExtension: "m4a").preferredMIMEType` yields on iOS 26.
            expected.append(Data("Content-Type: audio/x-m4a\r\n\r\n".utf8))
            expected.append(try Data(contentsOf: url))
            expected.append(Data("\r\n".utf8))
        }
        expected.append(Data("--\(boundary)--\r\n".utf8))
        return expected
    }

    private func makeClient(watching dir: URL?, failure: Error? = nil) -> ServerClient {
        MultipartStubProtocol.failure = failure
        MultipartStubProtocol.watchedDirectory = dir
        MultipartStubProtocol.receivedBody = Data()
        MultipartStubProtocol.filesDuringUpload = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MultipartStubProtocol.self]
        return ServerClient(session: URLSession(configuration: config))
    }

    private func request() -> URLRequest {
        var req = URLRequest(url: URL(string: "http://stub.invalid/api/sessions")!)
        req.httpMethod = "POST"
        return req
    }

    // --- framing --------------------------------------------------------

    @Test("body holds the manifest part, one part per audio file and the closing boundary")
    func exactFraming() async throws {
        let audioDir = try makeDir("audio")
        let bodyDir = try makeDir("body")
        defer {
            try? FileManager.default.removeItem(at: audioDir)
            try? FileManager.default.removeItem(at: bodyDir)
        }
        // 2.5 MiB: spans several copy chunks plus a short tail.
        let audio = audioDir.appending(path: "s01.m4a")
        try audioBytes(count: 2_621_440 + 17).write(to: audio)

        let bodyURL = try await MultipartBodyFile.write(
            manifest: manifest,
            audioFiles: ["segments/s01.m4a": audio],
            boundary: boundary,
            directory: bodyDir
        )

        #expect(bodyURL.deletingLastPathComponent().standardizedFileURL == bodyDir.standardizedFileURL)
        let expected = try expectedBody(audio: [("segments/s01.m4a", audio)])
        #expect(try Data(contentsOf: bodyURL) == expected)
    }

    @Test("every audio file gets its own part under its field name")
    func multipleAudioParts() async throws {
        let audioDir = try makeDir("audio")
        let bodyDir = try makeDir("body")
        defer {
            try? FileManager.default.removeItem(at: audioDir)
            try? FileManager.default.removeItem(at: bodyDir)
        }
        var files: [String: URL] = [:]
        for (index, id) in ["s01", "s02", "s03"].enumerated() {
            let url = audioDir.appending(path: "\(id).m4a")
            try audioBytes(count: 1000 + index).write(to: url)
            files["segments/\(id).m4a"] = url
        }

        let bodyURL = try await MultipartBodyFile.write(
            manifest: manifest, audioFiles: files, boundary: boundary, directory: bodyDir
        )

        // Dictionary iteration order is stable for the same instance.
        let expected = try expectedBody(audio: files.map { ($0.key, $0.value) })
        #expect(try Data(contentsOf: bodyURL) == expected)
    }

    @Test("an unknown file extension is sent as application/octet-stream")
    func unknownExtensionFallsBack() async throws {
        let audioDir = try makeDir("audio")
        let bodyDir = try makeDir("body")
        defer {
            try? FileManager.default.removeItem(at: audioDir)
            try? FileManager.default.removeItem(at: bodyDir)
        }
        let audio = audioDir.appending(path: "s01.zzunknown")
        try audioBytes(count: 10).write(to: audio)

        let bodyURL = try await MultipartBodyFile.write(
            manifest: manifest,
            audioFiles: ["segments/s01.m4a": audio],
            boundary: boundary,
            directory: bodyDir
        )

        let text = String(decoding: try Data(contentsOf: bodyURL), as: UTF8.self)
        #expect(text.contains("Content-Type: application/octet-stream\r\n\r\n"))
    }

    @Test("a missing audio file throws missingFile and leaves no partial body")
    func missingFileLeavesNothing() async throws {
        let bodyDir = try makeDir("body")
        defer { try? FileManager.default.removeItem(at: bodyDir) }
        let gone = bodyDir.appending(path: "nowhere/s01.m4a")

        await #expect {
            try await MultipartBodyFile.write(
                manifest: manifest,
                audioFiles: ["segments/s01.m4a": gone],
                boundary: boundary,
                directory: bodyDir
            )
        } throws: { error in
            guard case ServerClientError.missingFile(let url) = error else { return false }
            return url == gone
        }
        #expect(try contents(of: bodyDir).isEmpty)
    }

    @Test("a cancelled write throws CancellationError and leaves no partial body")
    func cancelledWriteLeavesNothing() async throws {
        let audioDir = try makeDir("audio")
        let bodyDir = try makeDir("body")
        defer {
            try? FileManager.default.removeItem(at: audioDir)
            try? FileManager.default.removeItem(at: bodyDir)
        }
        let audio = audioDir.appending(path: "s01.m4a")
        try audioBytes(count: 3_000_000).write(to: audio)
        let manifest = manifest
        let boundary = boundary

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MultipartBodyFile.write(
                manifest: manifest,
                audioFiles: ["segments/s01.m4a": audio],
                boundary: boundary,
                directory: bodyDir
            )
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try contents(of: bodyDir).isEmpty)
    }

    // --- upload + cleanup -----------------------------------------------

    @Test("upload streams the framed body from a temp file and removes it afterwards")
    func uploadSuccessCleansUp() async throws {
        let audioDir = try makeDir("audio")
        let bodyDir = try makeDir("body")
        defer {
            try? FileManager.default.removeItem(at: audioDir)
            try? FileManager.default.removeItem(at: bodyDir)
        }
        let audio = audioDir.appending(path: "s01.m4a")
        try audioBytes(count: 300_000).write(to: audio)
        let client = makeClient(watching: bodyDir)

        let (data, response) = try await client.sendMultipart(
            request(),
            manifest: manifest,
            audioFiles: ["segments/s01.m4a": audio],
            boundary: boundary,
            bodyDirectory: bodyDir
        )

        #expect((response as? HTTPURLResponse)?.statusCode == 202)
        #expect(data == Data("{}".utf8))
        #expect(MultipartStubProtocol.receivedBody == (try expectedBody(audio: [("segments/s01.m4a", audio)])))
        #expect(MultipartStubProtocol.filesDuringUpload.count == 1)
        #expect(try contents(of: bodyDir).isEmpty)
    }

    @Test("a failed upload still removes the temp body")
    func uploadFailureCleansUp() async throws {
        let audioDir = try makeDir("audio")
        let bodyDir = try makeDir("body")
        defer {
            try? FileManager.default.removeItem(at: audioDir)
            try? FileManager.default.removeItem(at: bodyDir)
        }
        let audio = audioDir.appending(path: "s01.m4a")
        try audioBytes(count: 5000).write(to: audio)
        let client = makeClient(watching: bodyDir, failure: URLError(.networkConnectionLost))

        await #expect(throws: URLError.self) {
            try await client.sendMultipart(
                request(),
                manifest: manifest,
                audioFiles: ["segments/s01.m4a": audio],
                boundary: boundary,
                bodyDirectory: bodyDir
            )
        }

        #expect(MultipartStubProtocol.filesDuringUpload.count == 1)
        #expect(try contents(of: bodyDir).isEmpty)
    }

    @Test("a missing audio file fails before any upload and leaves no temp body")
    func missingFileSkipsUpload() async throws {
        let bodyDir = try makeDir("body")
        defer { try? FileManager.default.removeItem(at: bodyDir) }
        let gone = bodyDir.appending(path: "nowhere/s01.m4a")
        let client = makeClient(watching: bodyDir)

        await #expect(throws: ServerClientError.self) {
            try await client.sendMultipart(
                request(),
                manifest: manifest,
                audioFiles: ["segments/s01.m4a": gone],
                boundary: boundary,
                bodyDirectory: bodyDir
            )
        }

        #expect(MultipartStubProtocol.receivedBody.isEmpty)
        #expect(try contents(of: bodyDir).isEmpty)
    }
}
