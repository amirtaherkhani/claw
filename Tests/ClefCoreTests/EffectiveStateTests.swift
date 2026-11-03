import Testing

@testable import ClefCore

@Suite("Effective plugin state")
struct EffectiveStateTests {
    let id = "ecc@ecc"

    @Test("Highest precedence wins and lower disagreeing layers are listed")
    func precedence() {
        let user = PluginLayer(source: .user, file: "~/.claude/settings.json", enabledPlugins: [id: false])
        let project = PluginLayer(source: .project, file: ".claude/settings.json", enabledPlugins: [id: true])
        let local = PluginLayer(source: .local, file: ".claude/settings.local.json", enabledPlugins: [id: false])
        let managed = PluginLayer(source: .managed, enabledPlugins: [id: true])

        let a = EffectivePluginState.resolve(id, layers: [user, project])
        #expect(a.enabled)
        #expect(a.decidedBy == .project)
        #expect(a.overridden == [.init(source: .user, value: false)])

        let b = EffectivePluginState.resolve(id, layers: [user, project, local])
        #expect(!b.enabled)
        #expect(b.decidedBy == .local)

        let c = EffectivePluginState.resolve(id, layers: [user, project, local, managed])
        #expect(c.enabled)
        #expect(c.decidedBy == .managed)
        #expect(EffectivePluginState.resolve(id, layers: [managed, local, project, user]) == c)
    }

    @Test("add-dir only counts when true")
    func addDir() {
        #expect(
            EffectivePluginState.resolve(id, layers: [PluginLayer(source: .addDir, enabledPlugins: [id: false])]).decidedBy == nil
        )
        #expect(EffectivePluginState.resolve(id, layers: [PluginLayer(source: .addDir, enabledPlugins: [id: true])]).enabled)
    }

    @Test("Unmentioned id falls back")
    func fallback() {
        let state = EffectivePluginState.resolve("zzz@zzz", layers: [PluginLayer(source: .user, enabledPlugins: [id: true])])
        #expect(state == EffectiveState(enabled: false, decidedBy: nil, file: nil, overridden: []))
    }
}
