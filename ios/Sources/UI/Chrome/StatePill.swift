import SwiftUI

/// Small tinted pill marking the conversational state. Three flavours:
/// recording (red, pulsing), listening (red, pulsing), speaking (warning).
///
/// On iPhone 17 Pro the same signal is mirrored into the Dynamic Island
/// via the live activity. This in-app pill is the fallback for screens
/// where the island isn't carrying the information.
public struct StatePill: View {
    public enum Kind: Sendable { case recording, listening, speaking }

    public let kind: Kind

    public init(kind: Kind) { self.kind = kind }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .opacity(pulsing ? 0.45 : 1.0)
                .animation(pulsing
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default, value: pulsing)
            Text(label)
                .font(Theme.font.caption.weight(.medium))
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, Theme.spacing.sm)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous).fill(bgColor)
        )
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch kind {
        case .recording: return "Aufnahme läuft"
        case .listening: return "höre zu"
        case .speaking:  return "Editor spricht"
        }
    }

    private var pulsing: Bool {
        switch kind { case .recording, .listening: return true; case .speaking: return false }
    }

    private var dotColor: Color {
        switch kind {
        case .recording, .listening: return Theme.color.status.destructive
        case .speaking:              return Theme.color.status.warning
        }
    }

    private var textColor: Color { dotColor }

    private var bgColor: Color {
        switch kind {
        case .recording, .listening: return Theme.color.tint.destructive10
        case .speaking:              return Theme.color.tint.warning10
        }
    }
}
