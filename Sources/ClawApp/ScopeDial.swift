import ClawCore
import SwiftUI

/// Write-scope selector drawn as a dial: named stops hang on a shallow ring along the bottom of the
/// toolbar. The ring turns like a carousel: the chosen stop sits at the lowest point with its
/// neighbours either side (wrapping round), and a stop that leaves one end comes back at the other.
/// Behaves as a segmented picker for VoiceOver and UI tests.
struct ScopeDial: View {
    let selection: SettingsScope
    let onSelect: (SettingsScope) -> Void

    static let stops: [SettingsScope] = [.user, .project, .local]

    // Ring geometry: a large circle whose bottom arc runs along the toolbar's lower edge.
    private let size = CGSize(width: 450, height: 46)
    private let radius: CGFloat = 900
    private let bottomY: CGFloat = 41  // centre of the selected dot
    private let step: Double = 7.7  // degrees between neighbouring stops

    /// Continuous turn of the ring, in stops. Only ever moves by the shortest way round.
    @State private var turn: Double

    init(selection: SettingsScope, onSelect: @escaping (SettingsScope) -> Void) {
        self.selection = selection
        self.onSelect = onSelect
        _turn = State(initialValue: Double(Self.stops.firstIndex(of: selection) ?? 0))
    }

    private var selectedIndex: Int { Self.stops.firstIndex(of: selection) ?? 0 }

    var body: some View {
        let center = CGPoint(x: size.width / 2, y: bottomY - radius)
        ZStack(alignment: .topLeading) {
            // The ring runs well past the outer stops, leaving open space at both ends.
            Ring(center: center, radius: radius, span: step * 1.8)
                .stroke(Theme.muted.opacity(0.35), lineWidth: 1)
            ForEach(Array(Self.stops.enumerated()), id: \.element) { index, scope in
                DialStop(
                    position: Double(index) - turn, count: Self.stops.count, step: step, center: center,
                    radius: radius, title: Self.title(scope), detail: Self.detail(scope)
                ) { onSelect(scope) }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onChange(of: selection) { _, _ in
            let count = Self.stops.count
            let current = ((Int(turn.rounded()) % count) + count) % count
            var delta = (selectedIndex - current + count) % count
            if delta > count / 2 { delta -= count }
            withAnimation(.smooth(duration: 0.75)) { turn += Double(delta) }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .accessibilityRepresentation {
            Picker("Write scope", selection: Binding(get: { selection }, set: { onSelect($0) })) {
                ForEach(Self.stops, id: \.self) { scope in Self.title(scope).tag(scope) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let count = Self.stops.count
        onSelect(Self.stops[(selectedIndex + delta + count) % count])
        return .handled
    }

    static func title(_ scope: SettingsScope) -> Text {
        switch scope {
        case .user: Text("User")
        case .project: Text("Project")
        case .local: Text("Local")
        case .managed: Text("Managed")
        }
    }

    private static func detail(_ scope: SettingsScope) -> Text {
        switch scope {
        case .user: Text("Every project on this Mac")
        case .project: Text("Shared with the repository")
        case .local: Text("Only you, in this project")
        case .managed: Text("Set by your organisation")
        }
    }
}

/// One named stop on the ring. Its animated `position` (in stops from the bottom) is wrapped round
/// the ring, and placement, tilt, size, colour and fade all derive from it, so every frame of a
/// turn is a smooth blend.
private struct DialStop: View, Animatable {
    var position: Double
    let count: Int
    let step: Double
    let center: CGPoint
    let radius: CGFloat
    let title: Text
    let detail: Text
    let action: () -> Void

    nonisolated var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        // Wrap into -count/2 ..< count/2 so a stop leaving one end re-enters at the other.
        let half = Double(count) / 2
        let wrapped = (position + half).truncatingRemainder(dividingBy: Double(count))
        let offset = (wrapped < 0 ? wrapped + Double(count) : wrapped) - half
        let angle = offset * step
        // 1 at the bottom of the ring, 0 one stop away or further.
        let focus = max(0, 1 - abs(offset))
        // Fully visible up to one stop out, gone by the ring's wrap point.
        let visibility = max(0, min(1, (half - abs(offset)) / (half - 1)))
        let radians = angle * .pi / 180
        let point = CGPoint(x: center.x + radius * sin(radians), y: center.y + radius * cos(radians))
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    title.foregroundStyle(Theme.muted.opacity(0.65)).opacity(1 - focus)
                    title.foregroundStyle(Theme.accent).opacity(focus)
                }
                .font(.system(size: 15, weight: .heavy, design: .monospaced))
                .textCase(.uppercase)
                .tracking(1.2)
                .scaleEffect(0.6 + 0.4 * focus, anchor: .bottom)
                ZStack {
                    Circle().fill(Theme.muted.opacity(0.5))
                    Circle().fill(Theme.accent).opacity(focus)
                }
                .frame(width: 3.5 + 2 * focus, height: 3.5 + 2 * focus)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(detail)
        .fixedSize()
        // The ring rises away from the bottom, so the stop leans back along its tangent.
        .rotationEffect(.degrees(-angle), anchor: .bottom)
        // A zero-height frame aligned to the bottom pins the dot to `point`; the name sits above it.
        .frame(height: 0, alignment: .bottom)
        .position(x: point.x, y: point.y + 2.75)
        .opacity(visibility)
        .allowsHitTesting(visibility > 0.5)
    }
}

/// The visible part of the ring: an arc of `span` degrees either side of the bottom.
private struct Ring: Shape {
    let center: CGPoint
    let radius: CGFloat
    let span: Double

    func path(in rect: CGRect) -> Path {
        // Sampled rather than addArc, so the short arc is drawn whatever the coordinate flip.
        Path { path in
            let samples = 64
            for sample in 0...samples {
                let degrees = -span + 2 * span * Double(sample) / Double(samples)
                let radians = degrees * .pi / 180
                let point = CGPoint(x: center.x + radius * sin(radians), y: center.y + radius * cos(radians))
                if sample == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}
