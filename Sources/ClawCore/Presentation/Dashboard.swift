import Foundation

/// Numbers for the Overview and the status bar, always computed from the last scan (FR-F01-1).
public struct OverviewStats: Sendable, Equatable {
    public let total: Int
    public let enabled: Int
    public let byBucket: [Bucket: Int]
    public let byConcept: [Concept: Int]
    public let enabledByConcept: [Concept: Int]
    public let problems: Int

    public init(items: [Item], problems: Int) {
        total = items.count
        enabled = items.filter(\.enabled).count
        byBucket = Dictionary(grouping: items, by: \.bucket).mapValues(\.count)
        byConcept = Dictionary(grouping: items, by: \.concept).mapValues(\.count)
        enabledByConcept = Dictionary(grouping: items.filter(\.enabled), by: \.concept).mapValues(\.count)
        self.problems = problems
    }

    public var editable: Int { byBucket[.yours] ?? 0 }
    public var attention: Int { byBucket[.attention] ?? 0 }
    public var enabledFraction: Double { total == 0 ? 0 : Double(enabled) / Double(total) }

    public func headline(pending: Int) -> String {
        if total == 0 { return "Nothing found yet. Run a scan." }
        if attention > 0 { return attention == 1 ? "1 item needs attention" : "\(attention) items need attention" }
        if pending > 0 { return pending == 1 ? "1 change is waiting for review" : "\(pending) changes are waiting for review" }
        return "Your setup looks healthy"
    }
}

/// A node in a source flow (left: where items come from; right: what you can do with them).
public struct FlowNode: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let count: Int
    public let bucket: Bucket?
}

/// Sources view for one concept, or the Scan view for all concepts (PRD F04, F02).
public struct SourceFlow: Sendable, Equatable {
    public let left: [FlowNode]
    public let right: [FlowNode]
    /// Links between left and right node ids, weighted by item count.
    public let links: [Link]

    public struct Link: Sendable, Equatable {
        public let from: String
        public let to: String
        public let weight: Int
    }

    static func origin(_ item: Item) -> (id: String, name: String) {
        switch item.classification.ownership {
        case .personal: ("files", "Your files")
        case .market: ("market", "Marketplaces")
        case .synced: ("claudeai", "claude.ai")
        case .plugin: ("plugin", "Inside plugins")
        case .managed: ("managed", "Organization")
        case .orphan: ("missing", "Missing source")
        }
    }

    /// Origins on the left, buckets on the right.
    public static func sources(of items: [Item]) -> SourceFlow {
        var counts: [String: (name: String, count: Int)] = [:]
        var weights: [String: Int] = [:]
        for item in items {
            let origin = origin(item)
            counts[origin.id, default: (origin.name, 0)].count += 1
            weights["\(origin.id)>\(item.bucket.rawValue)", default: 0] += 1
        }
        let order = ["files", "market", "claudeai", "plugin", "managed", "missing"]
        let left = order.compactMap { id -> FlowNode? in
            guard let entry = counts[id] else { return nil }
            return FlowNode(id: id, name: entry.name, subtitle: "\(entry.count) found", count: entry.count, bucket: nil)
        }
        return SourceFlow(left: left, right: bucketNodes(items), links: links(weights))
    }

    /// Concepts on the left, buckets on the right.
    public static func concepts(of items: [Item]) -> SourceFlow {
        var weights: [String: Int] = [:]
        for item in items { weights["\(item.concept.rawValue)>\(item.bucket.rawValue)", default: 0] += 1 }
        let byConcept = Dictionary(grouping: items, by: \.concept).mapValues(\.count)
        let left = Concept.allCases.map { concept in
            let count = byConcept[concept] ?? 0
            return FlowNode(
                id: concept.rawValue, name: ItemPresentation.conceptTitle(concept),
                subtitle: count == 0 ? "none" : "\(count) found", count: count, bucket: nil)
        }
        return SourceFlow(left: left, right: bucketNodes(items), links: links(weights))
    }

    static func bucketNodes(_ items: [Item]) -> [FlowNode] {
        let byBucket = Dictionary(grouping: items, by: \.bucket).mapValues(\.count)
        return Bucket.allCases.map { bucket in
            let count = byBucket[bucket] ?? 0
            return FlowNode(
                id: bucket.rawValue, name: ItemPresentation.bucketTitle(bucket),
                subtitle: "\(count) · \(ItemPresentation.bucketSubtitle(bucket))", count: count, bucket: bucket)
        }
    }

    static func links(_ weights: [String: Int]) -> [Link] {
        weights.keys.sorted().compactMap { key in
            let parts = key.split(separator: ">").map(String.init)
            guard parts.count == 2, let weight = weights[key] else { return nil }
            return Link(from: parts[0], to: parts[1], weight: weight)
        }
    }
}

/// Deterministic pseudo-random numbers for the particle visuals (same picture on every launch).
public struct SeededRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    /// SplitMix64.
    public mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

/// Points on a ring for the Overview visual. `lit` points show the enabled share.
public struct RingParticle: Sendable, Equatable {
    public let angle: Double
    public let radius: Double
    public let size: Double
    public let opacity: Double
    public let lit: Bool

    public static func ring(count: Int, enabledFraction: Double, seed: UInt64 = 7) -> [RingParticle] {
        var random = SeededRandom(seed: seed)
        let litCount = Int((Double(count) * max(0, min(1, enabledFraction))).rounded())
        return (0..<count).map { index in
            let angle = Double(index) / Double(max(count, 1)) * 2 * Double.pi + random.next() * 0.05
            return RingParticle(
                angle: angle, radius: 0.86 + random.next() * 0.14, size: 1.2 + random.next() * 2.2,
                opacity: 0.35 + random.next() * 0.65, lit: index < litCount)
        }
    }
}
