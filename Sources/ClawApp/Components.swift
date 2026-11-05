import ClawCore
import SwiftUI

/// Page title with the "Writes to" box on the right (prototype header).
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 26, weight: .semibold))
                // No vertical fixedSize here: at the near-zero width used to measure a window's minimum size,
                // it reports one character per line and forces the window to grow on pages without a ScrollView.
                Text(subtitle).foregroundStyle(Theme.muted).lineLimit(3)
            }
            Spacer(minLength: 16)
            trailing
        }
    }
}

extension PageHeader where Trailing == WritesToBox {
    init(title: String, subtitle: String, writesTo: String) {
        self.init(title: title, subtitle: subtitle) { WritesToBox(file: writesTo) }
    }
}

struct WritesToBox: View {
    let file: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Writes to").foregroundStyle(Theme.muted)
                Text(file).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
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
