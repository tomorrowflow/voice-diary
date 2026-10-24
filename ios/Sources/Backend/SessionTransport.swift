import Foundation

/// The server calls the walkthrough and the upload queue make. `ServerClient`
/// is the production conformance; tests inject a fake so these paths run
/// without HTTP requests or Keychain credentials.
protocol SessionTransport: Sendable {
    func health() async throws -> Data
    func todayCalendar(date: String, rsvpFilter: String) async throws -> Data
    func recordedDates(from: String?, to: String?) async throws -> [String]
    func uploadSession(
        manifest: Manifest,
        audioFiles: [String: URL]
    ) async throws -> SessionAccepted
}

extension SessionTransport {
    func todayCalendar(date: String) async throws -> Data {
        try await todayCalendar(date: date, rsvpFilter: ServerClient.defaultRSVPFilter)
    }
}

extension ServerClient: SessionTransport {}
