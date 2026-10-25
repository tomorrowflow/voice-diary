import AVFoundation
import Speech
import Testing
@testable import VoiceDiary

// Projection behind the buttons in PermissionsView. The view keeps the
// localized labels, icons and button styles and the real authorization
// requests; these tests pin which action each system status produces and
// that the dispatch reaches exactly one of request / nothing / Settings.
// Synthetic statuses only: nothing here asks for permission or opens
// Settings.

@Suite("PermissionActionState")
struct PermissionActionStateTests {
    @Test("a microphone status maps to its action state",
          arguments: [
            (AVAudioApplication.recordPermission.granted, PermissionActionState.alreadyGranted),
            (.denied, .openSettings),
            (.undetermined, .canRequest),
          ])
    func microphone(
        status: AVAudioApplication.recordPermission,
        expected: PermissionActionState
    ) {
        #expect(PermissionActionState(microphone: status) == expected)
    }

    @Test("a speech status maps to its action state",
          arguments: [
            (SFSpeechRecognizerAuthorizationStatus.authorized, PermissionActionState.alreadyGranted),
            (.denied, .openSettings),
            (.restricted, .openSettings),
            (.notDetermined, .canRequest),
          ])
    func speech(
        status: SFSpeechRecognizerAuthorizationStatus,
        expected: PermissionActionState
    ) {
        #expect(PermissionActionState(speech: status) == expected)
    }

    @Test("an unknown raw status falls back to canRequest")
    func unknownStatusFallsBack() throws {
        let speech = try #require(SFSpeechRecognizerAuthorizationStatus(rawValue: 99))
        #expect(PermissionActionState(speech: speech) == .canRequest)
        let microphone = try #require(AVAudioApplication.recordPermission(rawValue: 0x7a7a7a7a))
        #expect(PermissionActionState(microphone: microphone) == .canRequest)
    }

    @Test("dispatch runs only the handler for the state")
    func dispatch() {
        func calls(for state: PermissionActionState) -> [String] {
            var calls: [String] = []
            state.perform(
                request: { calls.append("request") },
                openSettings: { calls.append("settings") }
            )
            return calls
        }
        #expect(calls(for: .canRequest) == ["request"])
        #expect(calls(for: .alreadyGranted).isEmpty)
        #expect(calls(for: .openSettings) == ["settings"])
    }

    @Test("a microphone status dispatches through its projection",
          arguments: [
            (AVAudioApplication.recordPermission.granted, []),
            (.denied, ["settings"]),
            (.undetermined, ["request"]),
          ])
    func microphoneDispatch(status: AVAudioApplication.recordPermission, expected: [String]) {
        var calls: [String] = []
        PermissionActionState(microphone: status).perform(
            request: { calls.append("request") },
            openSettings: { calls.append("settings") }
        )
        #expect(calls == expected)
    }

    @Test("a speech status dispatches through its projection",
          arguments: [
            (SFSpeechRecognizerAuthorizationStatus.authorized, []),
            (.denied, ["settings"]),
            (.restricted, ["settings"]),
            (.notDetermined, ["request"]),
          ])
    func speechDispatch(status: SFSpeechRecognizerAuthorizationStatus, expected: [String]) {
        var calls: [String] = []
        PermissionActionState(speech: status).perform(
            request: { calls.append("request") },
            openSettings: { calls.append("settings") }
        )
        #expect(calls == expected)
    }

    @Test("alreadyGranted or a request in flight disables the button",
          arguments: [
            (PermissionActionState.canRequest, false, false),
            (.openSettings, false, false),
            (.alreadyGranted, false, true),
            (.canRequest, true, true),
            (.openSettings, true, true),
            (.alreadyGranted, true, true),
          ])
    func disabled(state: PermissionActionState, isBusy: Bool, expected: Bool) {
        #expect(state.isDisabled(isBusy: isBusy) == expected)
    }
}
