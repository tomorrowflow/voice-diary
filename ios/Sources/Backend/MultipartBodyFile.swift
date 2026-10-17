import Foundation
import UniformTypeIdentifiers

// Writes the POST /api/sessions multipart body to a temporary file so the
// upload can stream it with `URLSession.upload(for:fromFile:)` instead of
// holding every audio segment in memory.

enum MultipartBodyFile {
    /// Audio is copied in pieces this size, so peak memory stays flat
    /// however long the recording is.
    private static let copyChunkSize = 1 << 20

    /// Writes the manifest part and one part per audio file to a new file in
    /// `directory` and returns its URL. The caller owns the file and must
    /// delete it. If writing fails, the partial file is removed before the
    /// error propagates. Runs off the caller's actor and stops copying when
    /// the surrounding task is cancelled.
    @concurrent
    static func write(
        manifest: Manifest,
        audioFiles: [String: URL],   // multipart field name → on-disk URL
        boundary: String,
        directory: URL
    ) async throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestJSON = try encoder.encode(manifest)

        let bodyURL = directory.appending(path: "vd-upload-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: bodyURL.path])
        }
        // Uploads run in the background, possibly with the device locked.
        LocalStore.applyProtection(to: bodyURL)
        do {
            let out = try FileHandle(forWritingTo: bodyURL)
            defer { try? out.close() }

            let boundaryLine = Data("--\(boundary)\r\n".utf8)
            let crlf = Data("\r\n".utf8)

            // manifest part
            try out.write(contentsOf: boundaryLine)
            try out.write(contentsOf: Data(
                "Content-Disposition: form-data; name=\"manifest\"; filename=\"manifest.json\"\r\n".utf8
            ))
            try out.write(contentsOf: Data("Content-Type: application/json\r\n\r\n".utf8))
            try out.write(contentsOf: manifestJSON)
            try out.write(contentsOf: crlf)

            // audio parts
            for (fieldName, fileURL) in audioFiles {
                try Task.checkCancellation()
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    throw ServerClientError.missingFile(fileURL)
                }
                try out.write(contentsOf: boundaryLine)
                try out.write(contentsOf: Data(
                    "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".utf8
                ))
                try out.write(contentsOf: Data("Content-Type: \(mimeType(for: fileURL))\r\n\r\n".utf8))
                try copy(fileURL, to: out)
                try out.write(contentsOf: crlf)
            }

            try out.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
        return bodyURL
    }

    private static func copy(_ source: URL, to out: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: copyChunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            try out.write(contentsOf: chunk)
        }
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
