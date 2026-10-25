import AVFoundation
import Speech

// What a permission button in `PermissionsView` does when tapped, projected
// from the system authorization status. The view keeps the localized
// labels, icons and button styles and owns the real authorization requests
// and the Settings deep link; it hands them to `perform` as closures.
//
// Microphone: granted is already granted, denied opens Settings. Speech:
// authorized is already granted, denied and restricted open Settings. Every
// other status, including one added by a later OS, can be requested.

/// What the button will actually do when tapped — labels and the
/// disabled state derive from this, so the UI can never claim to
/// "request access" when the system has already cached an answer.
enum PermissionActionState: Equatable {
    /// First-time ask. Tapping triggers the system dialog.
    case canRequest
    /// Already granted. Button is disabled with a confirming label.
    case alreadyGranted
    /// Denied or restricted. Button deep-links to iOS Settings,
    /// because that's the only path back to "granted".
    case openSettings

    init(microphone status: AVAudioApplication.recordPermission) {
        switch status {
        case .granted:     self = .alreadyGranted
        case .denied:      self = .openSettings
        default:           self = .canRequest
        }
    }

    init(speech status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .authorized:           self = .alreadyGranted
        case .denied, .restricted:  self = .openSettings
        default:                    self = .canRequest
        }
    }

    /// `alreadyGranted` has nothing left to do, and a request in flight
    /// must not be started twice.
    func isDisabled(isBusy: Bool) -> Bool {
        isBusy || self == .alreadyGranted
    }

    func perform(request: () -> Void, openSettings: () -> Void) {
        switch self {
        case .canRequest:     request()
        case .alreadyGranted: break
        case .openSettings:   openSettings()
        }
    }
}
