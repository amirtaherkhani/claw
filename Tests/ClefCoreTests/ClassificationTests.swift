import Testing

@testable import ClefCore

@Suite("Plugin classification")
struct ClassificationTests {
    let markets: [String: MarketplaceRecord] = [
        "gh-market": MarketplaceRecord(name: "gh-market", source: .github),
        "local-dev": MarketplaceRecord(name: "local-dev", source: .directory, path: "/Users/mac/Developer/local-dev"),
    ]

    func classify(_ id: String, readFromFolder: String? = nil, relative: Bool? = nil, remote: String? = nil) -> Classification {
        PluginClassifier.classify(
            PluginRecord(id: id, installPath: "/cache/x", readFromFolder: readFromFolder),
            context: PluginClassifyContext(markets: markets, entrySourceIsRelative: relative, gitRemote: remote)
        )
    }

    @Test("Rules P1 to P7")
    func rules() {
        #expect(classify("nope").rule == "P1")
        #expect(classify("x@").rule == "P1")
        #expect(classify("@x").rule == "P1")
        #expect(classify("slack@synced").ownership == .synced)
        #expect(classify("mine@skills-dir").ownership == .personal)
        #expect(classify("tmp@inline").rule == "P4")
        #expect(classify("a@gone").ownership == .orphan)
        #expect(classify("a@gone").rule == "P5")
        #expect(classify("ecc@gh-market").ownership == .market)
        #expect(classify("ecc@gh-market").rule == "P7")
    }

    @Test("P6 needs a local marketplace and proof of in-place loading")
    func personalPlugin() {
        let inPlace = classify("nest@local-dev", readFromFolder: "/Users/mac/Developer/local-dev/plugins/nest")
        #expect(inPlace.ownership == .personal)
        #expect(inPlace.rule == "P6")

        let relative = classify("nest@local-dev", relative: true, remote: "git@example.com:me/x.git")
        #expect(relative.ownership == .personal)
        #expect(relative.evidence.contains { $0.contains("git remote") })

        // Local marketplace, entry points elsewhere (copied into the cache): never editable.
        #expect(classify("nest@local-dev", relative: false).ownership == .market)

        // Old CLI, cannot prove: conservative.
        let unknown = classify("nest@local-dev")
        #expect(unknown.ownership == .market)
        #expect(unknown.evidence.joined().contains("cannot prove"))
    }

    @Test("Only Personal is Yours")
    func buckets() {
        #expect(Ownership.personal.bucket == .yours)
        #expect(Ownership.orphan.bucket == .attention)
        for ownership in [Ownership.market, .synced, .plugin, .managed] {
            #expect(ownership.bucket == .readonly)
        }
    }

    @Test("Capabilities follow the PRD matrix")
    func capabilities() {
        #expect(Capabilities.forOwnership(.personal, isPlugin: true).edit)
        #expect(!Capabilities.forOwnership(.market, isPlugin: true).edit)
        #expect(Capabilities.forOwnership(.market, isPlugin: true).toggle)
        #expect(!Capabilities.forOwnership(.managed, isPlugin: true).toggle)
        #expect(!Capabilities.forOwnership(.plugin, isPlugin: false).remove)
        #expect(Capabilities.forOwnership(.orphan, isPlugin: true).removeLabel == "Remove entry")
    }

    @Test("Plugin id parts")
    func idParts() {
        let record = PluginRecord(id: "ecc@ecc-market", installPath: "")
        #expect(record.name == "ecc")
        #expect(record.origin == "ecc-market")
        #expect(PluginRecord(id: "solo", installPath: "").origin == nil)
    }
}
