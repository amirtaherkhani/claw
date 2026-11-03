import Foundation
import Testing

@testable import ClefCore

@Suite("Parsing and safety")
struct ParsingTests {
    @Test("Redactor masks env, headers, secret keys and URL credentials; keeps names")
    func redact() throws {
        let json = """
            {"command":"npx","args":["-y","some-mcp"],
             "env":{"API_KEY":"fake-value-1","PLAIN":"fake-value-2"},
             "headers":{"Authorization":"Bearer fake-value-3"},
             "url":"https://user:pw@example.com/mcp?token=fake-value-4&x=1",
             "oauth":{"clientId":"public-id","clientSecret":"fake-value-5"}}
            """
        let red = Redactor.redact(try JSONValue.parse(Data(json.utf8)))
        let text = String(decoding: try JSONEncoder().encode(red), as: UTF8.self)
        for secret in ["fake-value-1", "fake-value-2", "fake-value-3", "fake-value-4", "fake-value-5", "pw@"] {
            #expect(!text.contains(secret), "leaked \(secret)")
        }
        #expect(red["env"]?.objectValue?.keys.sorted() == ["API_KEY", "PLAIN"])
        #expect(red["oauth"]?["clientId"]?.stringValue == "public-id")
        #expect(red["command"]?.stringValue == "npx")
        #expect(Redactor.maskURL("not a url") == "not a url")
    }

    @Test("Strict JSON: comments and trailing commas are rejected")
    func strictJSON() {
        #expect(throws: (any Error).self) { try JSONValue.parse(Data("{ // c\n \"a\": 1 }".utf8)) }
        for bad in ["{ \"a\": 1, }", "[1,2,]", "[01]", "{'a':1}", "\u{FEFF}{}", "{\"a\":1} x", "{\"a\":\"\t\"}", "[1.]", "NaN"] {
            #expect(throws: StrictJSONError.self, "\(bad)") { try StrictJSON.validate(Data(bad.utf8)) }
        }
        for good in [
            "{}", "[]", "0", "-0.5e+10", "\"\\u00e9\\n\"", "{\"a\":[true,false,null,{\"b\":\"é\"}]}", " \n{ \"a\" : 1 }\r\n",
        ] {
            #expect(throws: Never.self, "\(good)") { try StrictJSON.validate(Data(good.utf8)) }
        }
        #expect((try? JSONValue.parse(Data("{\"a\":true}".utf8)))?["a"]?.boolValue == true)
    }

    @Test("Frontmatter: fields, quotes, folded block, body")
    func frontmatter() throws {
        let text =
            "---\r\nname: \"plan-review\"\r\ndescription: >\r\n  Reviews a plan\r\n  before coding.\r\nuser-invocable: false\r\n---\r\n# Body\r\n"
        let fm = try #require(Frontmatter.parse(text))
        #expect(fm["name"] == "plan-review")
        #expect(fm["description"] == "Reviews a plan before coding.")
        #expect(fm["user-invocable"] == "false")
        #expect(fm.body.hasPrefix("# Body"))
        #expect(Frontmatter.parse("# no fence") == nil)
        #expect(Frontmatter.parse("---\nname: x\n") == nil)
    }

    @Test("Plugin list: notices before JSON, extra keys, bad entries skipped")
    func pluginList() throws {
        let output = """
            Update available: run claude update
            [{"id":"ecc@ecc","version":"1.2.0","scope":"user","enabled":true,"installPath":"/c/ecc","futureKey":{"a":1}},{"id":"no-path@x"},{"id":"bad id; rm -rf ~@x","installPath":"/c/bad"},{"id":"nest@local-dev","scope":"project","enabled":false,"installPath":"/c/n","readFromFolder":"/dev/nest","projectPath":"/p"}]
            """
        let result = try PluginListParser.parse(Data(output.utf8))
        #expect(result.plugins.map(\.id) == ["ecc@ecc", "nest@local-dev"])
        #expect(result.plugins[1].readFromFolder == "/dev/nest")
        #expect(result.plugins[1].projectPath == "/p")
        #expect(result.problems.count == 2)
        #expect(throws: CommandError.self) { try PluginListParser.parse(Data("oops".utf8)) }
    }

    @Test("Name validation rejects hostile names")
    func names() {
        for good in ["ecc", "ecc@ecc", "searchfit-seo@searchfit", "a.b_c-1@m2"] {
            #expect(NameValidator.isValidPluginId(good), "\(good)")
        }
        for bad in ["", "-rf", "a b", "a;b", "../x", "a@b@c", "a/b@m", "\"q\"", "x@", "@x", String(repeating: "a", count: 129)] {
            #expect(!NameValidator.isValidPluginId(bad), "\(bad)")
        }
    }

    @Test("Settings loader turns bad files into problems")
    func settingsProblems() {
        let fs = MemoryFileSystem([
            "/h/.claude/settings.json": "{ \"enabledPlugins\": { \"a@m\": true, \"b@m\": \"yes\" }, \"skillOverrides\": [] }",
            "/p/.claude/settings.json": "{ not json",
            "/p/.claude/settings.local.json": "[1,2]",
        ])
        let env = ClaudeEnvironment(home: "/h", managedDir: "/managed", projects: ["/p"])
        let result = SettingsLoader(fileSystem: fs).loadAll(environment: env)
        #expect(result.layers.count == 1)
        #expect(result.layers.first?.enabledPlugins == ["a@m": true])
        #expect(result.problems.filter { $0.severity == .error }.count == 2)
        #expect(result.problems.contains { $0.message.contains("b@m") })
        #expect(result.problems.contains { $0.message.contains("skillOverrides") })
    }

    @Test("Environment honours CLAUDE_CONFIG_DIR and CLAUDE_CODE_PLUGIN_CACHE_DIR; empty means unset")
    func environment() {
        let env = ClaudeEnvironment.current(environment: [
            "HOME": "/h", "CLAUDE_CONFIG_DIR": "/cfg", "CLAUDE_CODE_PLUGIN_CACHE_DIR": "",
        ])
        #expect(env.configDir == "/cfg")
        #expect(env.pluginsDir == "/cfg/plugins")
        #expect(env.userSettingsFile == "/cfg/settings.json")
        #expect(ClaudeEnvironment.current(environment: ["HOME": "/h"]).configDir == "/h/.claude")
    }

    @Test("Marketplaces: string or object source, relative entries, git remote masked")
    func marketplaces() {
        let fs = MemoryFileSystem([
            "/h/.claude/plugins/known_marketplaces.json": """
            {"ecc":{"source":{"source":"github","repo":"o/ecc"},"installLocation":"/h/.claude/plugins/marketplaces/ecc"},
             "local-dev":{"source":{"source":"directory","path":"/dev/m"}},
             "odd":{"installLocation":"/x"}}
            """,
            "/dev/m/.claude-plugin/marketplace.json": """
            {"name":"local-dev","plugins":[{"name":"nest","source":"./plugins/nest"},{"name":"far","source":{"source":"github","repo":"o/far"}}]}
            """,
            "/dev/m/.git/config":
                "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = https://me:fake-token@github.com/me/m.git\n",
        ])
        let reader = MarketplaceReader(fileSystem: fs)
        let (markets, problems) = reader.readKnown(file: "/h/.claude/plugins/known_marketplaces.json")
        #expect(markets["ecc"]?.source == .github)
        #expect(markets["local-dev"]?.path == "/dev/m")
        #expect(markets["odd"]?.source == .other("unknown"))
        #expect(problems.count == 1)

        let local = markets["local-dev"]!
        #expect(reader.entrySourceIsRelative(market: local, pluginName: "nest") == true)
        #expect(reader.entrySourceIsRelative(market: local, pluginName: "far") == false)
        #expect(reader.entrySourceIsRelative(market: local, pluginName: "missing") == nil)

        let remote = reader.gitRemote(folder: "/dev/m")
        #expect(remote != nil)
        #expect(!(remote ?? "").contains("fake-token"))
    }
}
