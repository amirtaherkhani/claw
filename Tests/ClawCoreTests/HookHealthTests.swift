import Foundation
import Testing

@testable import ClawCore

/// M2.15: each hook is checked without running it, and shows OK, a warning or an error with the reason.
@Suite("Hook health check")
struct HookHealthTests {
    static let fs = MemoryFileSystem(
        ["/h/scripts/format.sh": "#!/bin/sh\n", "/h/scripts/notes.txt": "x", "/p/hooks/check.py": "print()"],
        notExecutable: ["/h/scripts/notes.txt", "/p/hooks/check.py"])
    static let context = HookHealth.Context(home: "/h", projectDir: "/p", pluginRoot: nil, probe: fs)

    func check(_ handler: String, event: String = "PostToolUse", matcher: String? = nil) throws -> [Problem] {
        HookHealth.check(
            event: event, matcher: matcher, handler: try JSONValue.parse(Data(handler.utf8)), context: Self.context)
    }

    func severity(_ problems: [Problem]) -> Problem.Severity? {
        problems.contains { $0.severity == .error } ? .error : problems.first?.severity
    }

    @Test(
        "A good hook has no problems",
        arguments: [
            #"{"type":"command","command":"~/scripts/format.sh --fix"}"#,
            #"{"type":"command","command":"$HOME/scripts/format.sh"}"#,
            #"{"type":"command","command":"python3 \"$CLAUDE_PROJECT_DIR\"/hooks/check.py"}"#,
            #"{"type":"command","command":"npx prettier --write","timeout":30}"#,
            #"{"type":"http","url":"https://hooks.example.com/x"}"#,
            #"{"type":"prompt","prompt":"Is it done?"}"#,
        ])
    func good(handler: String) throws {
        #expect(try check(handler, matcher: "Edit|Write").isEmpty)
    }

    @Test("Unknown event is an error")
    func unknownEvent() throws {
        let problems = try check(#"{"type":"command","command":"npx x"}"#, event: "Stopp")
        #expect(severity(problems) == .error)
        #expect(problems.first?.message.contains("Stopp") == true)
    }

    @Test(
        "Unknown type, or a type without its field, is an error",
        arguments: [
            #"{"type":"cmd","command":"npx x"}"#, #"{"type":"command"}"#, #"{"type":"http"}"#,
        ])
    func badType(handler: String) throws {
        #expect(severity(try check(handler)) == .error)
    }

    @Test("A matcher that is not a valid pattern is an error; * and empty are fine")
    func matcher() throws {
        #expect(severity(try check(#"{"type":"command","command":"npx x"}"#, matcher: "Edit(")) == .error)
        #expect(try check(#"{"type":"command","command":"npx x"}"#, matcher: "*").isEmpty)
        #expect(try check(#"{"type":"command","command":"npx x"}"#, matcher: "").isEmpty)
    }

    @Test("A missing script is an error that names it")
    func missing() throws {
        let problems = try check(#"{"type":"command","command":"~/scripts/gone.sh"}"#)
        #expect(severity(problems) == .error)
        #expect(problems.first?.message == "Script not found: ~/scripts/gone.sh")
        #expect(severity(try check(#"{"type":"command","command":"bash /h/scripts/gone.sh"}"#)) == .error)
    }

    @Test("A script that cannot run is a warning; one given to an interpreter need not be executable")
    func notExecutable() throws {
        let problems = try check(#"{"type":"command","command":"/h/scripts/notes.txt"}"#)
        #expect(severity(problems) == .warning)
        #expect(problems.first?.message == "Script is not executable: ~/scripts/notes.txt")
        #expect(try check(#"{"type":"command","command":"python3 /p/hooks/check.py"}"#).isEmpty)
    }

    @Test("A timeout that is not a positive number is a warning", arguments: ["0", "-5", #""ten""#])
    func timeout(value: String) throws {
        #expect(severity(try check(#"{"type":"command","command":"npx x","timeout":\#(value)}"#)) == .warning)
    }

    @Test("Paths that cannot be resolved are not reported, and arguments are never shown")
    func unresolvedAndSecret() throws {
        let noProject = HookHealth.Context(home: "/h", projectDir: nil, pluginRoot: nil, probe: Self.fs)
        let handler = try JSONValue.parse(Data(#"{"type":"command","command":"$CLAUDE_PROJECT_DIR/x.sh"}"#.utf8))
        #expect(HookHealth.check(event: "Stop", matcher: nil, handler: handler, context: noProject).isEmpty)
        let secret = try check(#"{"type":"command","command":"/h/scripts/gone.sh --token fake-secret-7"}"#)
        #expect(!secret.map { $0.message }.joined().contains("fake-secret-7"))
    }

    @Test("The scan puts the check on each hook item")
    func scan() async throws {
        let env = ClaudeEnvironment(home: "/h", managedDir: "/managed", projects: [])
        let settings =
            #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/scripts/gone.sh"}]}],"#
            + #""PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"~/scripts/format.sh"}]}]}}"#
        let fs = MemoryFileSystem(["/h/.claude/settings.json": settings, "/h/scripts/format.sh": "#!/bin/sh\n"])
        let result = await ConfigScanner(environment: env, fileSystem: fs, cli: nil).scan()
        let hooks = result.items.filter { $0.concept == .hooks }
        let stop = try #require(hooks.first { $0.name.hasPrefix("Stop") })
        let edit = try #require(hooks.first { $0.name.hasPrefix("PostToolUse") })
        #expect(ItemPresentation.health(stop) == .error("Script not found: ~/scripts/gone.sh"))
        #expect(ItemPresentation.health(edit) == .ok)
    }
}
