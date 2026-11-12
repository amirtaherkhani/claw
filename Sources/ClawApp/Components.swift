import ClawCore
import SwiftUI

extension View {
    /// Centres an empty state in the space its parent offers. `ContentUnavailableView` sizes to its content here,
    /// so a leading stack or the top-leading page frame would otherwise pin it to the corner.
    func centeredEmptyState() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Page title with the "Writes to" box on the right (prototype header).
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        // Side by side on a wide window; the trailing box moves under the title on a narrow one.
        AdaptiveRow(spacing: 24, minLead: 300) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 26, weight: .semibold))
                // No vertical fixedSize here: at the near-zero width used to measure a window's minimum size,
                // it reports one character per line and forces the window to grow on pages without a ScrollView.
                Text(subtitle).foregroundStyle(Theme.muted).lineLimit(3)
            }
            trailing
        }
    }
}

/// Two views: side by side when the first gets at least `minLead` next to the second at its ideal width,
/// otherwise the second goes under the first. Keeps headers readable on any window width.
struct AdaptiveRow: Layout {
    var spacing: CGFloat = 24
    var minLead: CGFloat = 300

    private func trailingSize(_ subviews: Subviews) -> CGSize {
        subviews.count > 1 ? subviews[1].sizeThatFits(.unspecified) : .zero
    }

    private func fits(_ width: CGFloat, _ subviews: Subviews) -> Bool {
        subviews.count < 2 || width >= minLead + spacing + trailingSize(subviews).width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minLead + spacing + trailingSize(subviews).width
        if fits(width, subviews) {
            let trailing = trailingSize(subviews)
            let lead = subviews.first?.sizeThatFits(.init(width: width - trailing.width - spacing, height: nil)) ?? .zero
            return CGSize(width: width, height: max(lead.height, trailing.height))
        }
        let heights = subviews.map { $0.sizeThatFits(.init(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if fits(bounds.width, subviews) {
            let trailing = trailingSize(subviews)
            subviews.first?.place(
                at: bounds.origin, proposal: .init(width: bounds.width - trailing.width - spacing, height: nil))
            if subviews.count > 1 {
                subviews[1].place(at: CGPoint(x: bounds.maxX - trailing.width, y: bounds.minY), proposal: .init(trailing))
            }
            return
        }
        var y = bounds.minY
        for subview in subviews {
            let proposal = ProposedViewSize(width: bounds.width, height: nil)
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: proposal)
            y += subview.sizeThatFits(proposal).height + spacing
        }
    }
}

extension View {
    /// The page as it is when it fits the window's height, otherwise inside a scroll view. A page that does not
    /// scroll would make a short window grow past the screen.
    func scrollsWhenShort() -> some View {
        ViewThatFits(in: .vertical) {
            self
            ScrollView { self }
        }
    }

    /// A sheet's size, never larger than the screen it opens on, so its buttons stay reachable on any display.
    func adaptiveSheet(width: CGFloat, height: CGFloat? = nil) -> some View {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return frame(width: min(width, screen.width - 40), height: height.map { min($0, screen.height - 80) })
    }
}

extension PageHeader where Trailing == WritesToBox {
    init(title: String, subtitle: String, writesTo: String, note: String? = nil) {
        self.init(title: title, subtitle: subtitle) { WritesToBox(file: writesTo, note: note) }
    }
}

/// The file the switch writes to (FR-F13-4), what that file means (FR-F13-5), and the backup promise.
struct WritesToBox: View {
    let file: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Writes to").foregroundStyle(Theme.muted)
                Text(file).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            if let note {
                // No vertical fixedSize: see PageHeader. Two lines hold every note.
                Label(note, systemImage: "person.2").font(.caption).foregroundStyle(Theme.attention).lineLimit(2)
            }
            Label("Backup before every apply", systemImage: "checkmark.shield")
                .foregroundStyle(Theme.muted)
        }
        .font(.callout)
        .panel(padding: 12)
        .frame(maxWidth: 360, alignment: .trailing)
    }
}

/// Outlined pill with a coloured dot and the bucket name (colour never carries meaning alone).
struct BucketBadge: View {
    let bucket: Bucket

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.color(bucket)).frame(width: 7, height: 7)
            Text(ItemPresentation.bucketTitle(bucket))
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .overlay { Capsule().strokeBorder(Theme.color(bucket).opacity(0.6)) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Owner: \(ItemPresentation.bucketTitle(bucket))")
    }
}

/// Rounded square with the item's first letter, tinted by owner group as on the board.
struct Monogram: View {
    let text: String
    let bucket: Bucket
    var size: CGFloat = 24

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(Theme.color(bucket))
            .frame(width: size, height: size)
            .background(
                Theme.color(bucket).opacity(0.16),
                in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// Selectable outlined chip (filters, scan targets).
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Color.black : Theme.text)
                .background(selected ? Theme.accent : Color.clear, in: Capsule())
                .overlay { Capsule().strokeBorder(selected ? Color.clear : Theme.border) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Unified-diff style preview lines.
struct DiffView: View {
    let lines: [DiffLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines) { line in
                HStack(alignment: .top, spacing: 6) {
                    Text(prefix(line.kind)).foregroundStyle(color(line.kind))
                    Text(line.text).foregroundStyle(line.kind == .note ? Theme.muted : color(line.kind))
                }
                .font(.callout.monospaced())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .textSelection(.enabled)
    }

    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .context: " "
        case .removed: "-"
        case .added: "+"
        case .note: "·"
        }
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .context: Theme.text
        case .removed: Theme.removed
        case .added: Theme.added
        case .note: Theme.muted
        }
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.panelRaised, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.border) }
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Dashed drop target with a Browse button (Projects, Add plugin).
struct DropZone: View {
    let title: String
    let detail: String
    let browse: () -> Void
    let drop: (URL) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus").font(.system(size: 26)).foregroundStyle(Theme.muted)
            Text(title).font(.headline)
            Button("or Browse…", action: browse)
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.accent)
            Text(detail).font(.callout).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(targeted ? Theme.accent.opacity(0.08) : Color.clear)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(targeted ? Theme.accent : Theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            drop(url)
            return true
        } isTargeted: {
            targeted = $0
        }
    }
}
