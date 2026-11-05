import ClawCore
import SwiftUI

/// Colours from the prototype. Flat near-black content; the accent is the one rebrandable colour.
/// Content-layer surfaces use solid fills only; glass comes from system chrome (sidebar, toolbar, sheets).
enum Theme {
    static let canvas = Color(hex: 0x0B0B0C)
    static let panel = Color(hex: 0x121214)
    static let panelRaised = Color(hex: 0x17171A)
    static let border = Color(hex: 0x232327)
    static let text = Color(hex: 0xF2F2F3)
    static let muted = Color(hex: 0x8E8E93)
    static let accent = Color(hex: 0xD4F53C)
    static let yours = Color(hex: 0xFFD60A)
    static let readonly = Color(hex: 0x6EA3FF)
    static let attention = Color(hex: 0xFF7A59)
    static let danger = Color(hex: 0xFF8F85)
    static let removed = Color(hex: 0xFF6B6B)
    static let added = Color(hex: 0x7EE08A)
    static let segment = Color(hex: 0x2E2E33)
    static let railSelected = Color(hex: 0x1C1C1F)
    static let railLabel = Color(hex: 0x9A9AA0)
    static let railWidth: CGFloat = 76

    static func color(_ bucket: Bucket) -> Color {
        switch bucket {
        case .yours: yours
        case .readonly: readonly
        case .attention: attention
        }
    }

    static func symbol(_ bucket: Bucket) -> String {
        switch bucket {
        case .yours: "person.crop.circle"
        case .readonly: "lock"
        case .attention: "exclamationmark.triangle"
        }
    }

    static func symbol(_ concept: Concept) -> String {
        switch concept {
        case .plugins: "puzzlepiece.extension"
        case .skills: "sparkles"
        case .commands: "command"
        case .rules: "doc.text"
        case .agents: "person.2"
        case .mcp: "server.rack"
        case .hooks: "bolt"
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// Hairline-bordered panel used for cards and lists (content layer, no glass).
struct Panel: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border) }
    }
}

extension View {
    func panel(padding: CGFloat = 16) -> some View { modifier(Panel(padding: padding)) }
}
