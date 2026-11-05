import ClawCore
import SwiftUI

/// First screen (PRD F01): particle ring with the enabled share, headline, and summary cards.
struct OverviewView: View {
    let model: AppModel

    var body: some View {
        if model.result == nil {
            ContentUnavailableView {
                Label("No scan yet", systemImage: "circle.hexagongrid")
            } description: {
                Text(
                    "Claw reads your Claude Code configuration and sorts every item by who owns it. Scanning never changes a file."
                )
            } actions: {
                Button("Scan all") { model.startScan() }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isScanning)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero
                    cards
                    conceptTiles
                }
                .padding(28)
            }
        }
    }

    private var stats: OverviewStats { model.stats }

    private var hero: some View {
        HStack(spacing: 40) {
            ZStack {
                ParticleRingView(fraction: stats.enabledFraction)
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(stats.enabled)").font(.system(size: 54, weight: .semibold))
                        Text("of \(stats.total)").font(.title3).foregroundStyle(Theme.muted)
                    }
                    Text("ENABLED").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(Theme.accent)
                    Text("\(stats.total) items across 7 types").font(.callout).foregroundStyle(Theme.muted)
                }
                .accessibilityElement(children: .combine)
            }
            .frame(width: 320, height: 320)

            VStack(alignment: .leading, spacing: 14) {
                Text(stats.headline(pending: model.queue.count))
                    .font(.system(size: 30, weight: .semibold))
                if let result = model.result {
                    HStack(spacing: 4) {
                        Text("Last read")
                        Text(result.finishedAt, format: .relative(presentation: .named))
                        Text("· \(model.scope.rawValue.capitalized) scope")
                    }
                    .foregroundStyle(Theme.muted)
                }
                if !model.queue.isEmpty {
                    Button("Review \(ItemPresentation.counted(model.queue.count, "change")) →") { model.showReview = true }
                        .buttonStyle(.link)
                }
                HStack(spacing: 10) {
                    Button("Scan all →") { model.startScan() }
                        .disabled(model.isScanning)
                    if stats.attention > 0 {
                        Button("Show items that need attention") { model.destination = .scan }
                    }
                }
                .controlSize(.large)
            }
            Spacer(minLength: 0)
        }
    }

    private var cards: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(stats.editable)").font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.yours)
                Text("items you own and can edit").foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("0").font(.system(size: 34, weight: .semibold))
                    Text("changes applied · 7 days").foregroundStyle(Theme.muted)
                }
                WeekBars(values: Array(repeating: 0, count: 7))
                Text("Applying changes arrives with the safe write pipeline (M2).")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()

            VStack(alignment: .leading, spacing: 8) {
                Label("BACKUP", systemImage: "checkmark.shield").font(.caption.weight(.semibold)).tracking(1.5)
                    .foregroundStyle(Theme.accent)
                LabeledContent("Next", value: String(localized: "Before every apply"))
                LabeledContent("Recent", value: String(localized: "No backups yet"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }

    private var conceptTiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(Concept.allCases, id: \.self) { concept in
                Button {
                    model.destination = .concept(concept)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: Theme.symbol(concept)).foregroundStyle(Theme.accent)
                        Text(ItemPresentation.conceptTitle(concept)).font(.headline)
                        Text("\(stats.enabledByConcept[concept] ?? 0) / \(stats.byConcept[concept] ?? 0) on")
                            .font(.callout).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel(padding: 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(ItemPresentation.conceptTitle(concept)): \(stats.enabledByConcept[concept] ?? 0) of \(stats.byConcept[concept] ?? 0) on"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Configuration types")
    }
}

struct WeekBars: View {
    let values: [Int]

    var body: some View {
        let top = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 2)
                    .fill(value > 0 ? Theme.accent : Theme.border)
                    .frame(width: 14, height: 4 + 30 * CGFloat(value) / CGFloat(top))
            }
        }
        .frame(height: 36, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// Ring of particles; lit particles show the enabled share. Static when Reduce Motion is on (FR-F01-5).
struct ParticleRingView: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let particles = RingParticle.ring(count: 180, enabledFraction: fraction)
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let time: Double = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let centerX = Double(size.width) / 2
                let centerY = Double(size.height) / 2
                let radius = Double(min(size.width, size.height)) / 2 - 6
                for (index, particle) in particles.enumerated() {
                    let twinkle: Double = reduceMotion ? 1.0 : 0.65 + 0.35 * sin(time * 1.2 + Double(index) * 0.7)
                    let x: Double = centerX + cos(particle.angle - Double.pi / 2) * radius * particle.radius
                    let y: Double = centerY + sin(particle.angle - Double.pi / 2) * radius * particle.radius
                    let rect = CGRect(
                        x: x - particle.size / 2, y: y - particle.size / 2, width: particle.size, height: particle.size)
                    let color = particle.lit ? Theme.accent : Theme.muted
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(particle.opacity * twinkle)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
