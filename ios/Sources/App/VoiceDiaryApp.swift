import SwiftUI

@main
struct VoiceDiaryApp: App {
    init() {
        Log.app.info("Voice Diary ready")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Theme.color.text.link)
                .background(Theme.color.bg.surface.ignoresSafeArea())
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            CaptureView()
                .tabItem { Label("Aufnahme", systemImage: "mic.circle") }

            DebugUploadView()
                .tabItem { Label("Test-Upload", systemImage: "arrow.up.circle") }

            DebugSettingsView()
                .tabItem { Label("Server", systemImage: "gear") }
        }
        .font(Theme.font.body)
    }
}

#Preview {
    RootView()
}
