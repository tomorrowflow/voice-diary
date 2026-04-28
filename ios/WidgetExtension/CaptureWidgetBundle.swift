import SwiftUI
import WidgetKit

// Entry point for the widget extension target.

@main
struct CaptureWidgetBundle: WidgetBundle {
    var body: some Widget {
        LockScreenCaptureWidget()
        CaptureLiveActivity()
    }
}
