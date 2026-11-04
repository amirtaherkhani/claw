import ClawCore
import SwiftUI

/// Left nodes (sources or concepts) linked to right nodes (buckets). Right nodes are buttons.
struct FlowView: View {
    let flow: SourceFlow
    let onSelect: (FlowNode) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let left = positions(count: flow.left.count, x: size.width * 0.2, height: size.height)
            let right = positions(count: flow.right.count, x: size.width * 0.8, height: size.height)
            ZStack {
                Canvas { context, _ in
                    for link in flow.links {
                        guard let from = flow.left.firstIndex(where: { $0.id == link.from }),
                            let to = flow.right.firstIndex(where: { $0.id == link.to })
                        else { continue }
                        let start = CGPoint(x: left[from].x + 70, y: left[from].y)
                        let end = CGPoint(x: right[to].x - 90, y: right[to].y)
                        var path = Path()
                        path.move(to: start)
                        let mid = (start.x + end.x) / 2
                        path.addCurve(
                            to: end, control1: CGPoint(x: mid, y: start.y), control2: CGPoint(x: mid, y: end.y))
                        let width = 1 + log2(Double(link.weight) + 1) * 1.4
                        let color = flow.right[to].bucket.map(Theme.color) ?? Theme.muted
                        context.stroke(path, with: .color(color.opacity(0.35)), lineWidth: width)
                    }
                }
                ForEach(Array(flow.left.enumerated()), id: \.element.id) { index, node in
                    NodeLabel(node: node, color: Theme.muted, alignment: .trailing)
                        .frame(width: 140, alignment: .trailing)
                        .position(left[index])
                }
                ForEach(Array(flow.right.enumerated()), id: \.element.id) { index, node in
                    Button {
                        onSelect(node)
                    } label: {
                        NodeLabel(node: node, color: node.bucket.map(Theme.color) ?? Theme.muted, alignment: .leading)
                            .padding(10)
                            .frame(width: 190, alignment: .leading)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(right[index])
                    .accessibilityLabel("\(node.name), \(node.subtitle)")
                }
            }
        }
        .frame(minHeight: 300)
    }

    private func positions(count: Int, x: CGFloat, height: CGFloat) -> [CGPoint] {
        (0..<count).map { index in CGPoint(x: x, y: height * CGFloat(index + 1) / CGFloat(count + 1)) }
    }
}

private struct NodeLabel: View {
    let node: FlowNode
    let color: Color
    let alignment: HorizontalAlignment

    var body: some View {
        HStack(spacing: 8) {
            if alignment == .leading { Circle().fill(color).frame(width: 8, height: 8) }
            VStack(alignment: alignment, spacing: 2) {
                HStack(spacing: 4) {
                    Text(node.name).font(.callout.weight(.semibold))
                    if node.bucket != nil { Text("›").foregroundStyle(Theme.muted) }
                }
                Text(node.subtitle).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
            }
            if alignment == .trailing { Circle().fill(color).frame(width: 6, height: 6) }
        }
    }
}
