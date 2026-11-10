import Foundation

/// Checks one hook handler without running it (ROADMAP M2.15): the event and type are known, the matcher is a
/// valid pattern, the script exists and can run, the timeout makes sense. Only file metadata is asked for; no
/// file is read and nothing is executed. Messages name the script path, never the arguments, which may hold a
/// secret. Whether the Claude desktop app shows its own hook status, and with which rules, is [U] (spike S15).
public enum HookHealth {
    /// Hook events [V `hooks`, PRD F15].
    public static let events: Set<String> = [
        "SessionStart", "Setup", "UserPromptSubmit", "UserPromptExpansion", "PreToolUse", "PermissionRequest",
        "PermissionDenied", "PostToolUse", "PostToolUseFailure", "PostToolBatch", "Notification", "MessageDisplay",
        "SubagentStart", "SubagentStop", "TaskCreated", "TaskCompleted", "Stop", "StopFailure", "TeammateIdle",
        "InstructionsLoaded", "ConfigChange", "CwdChanged", "DirectoryAdded", "FileChanged", "WorktreeCreate",
        "WorktreeRemove", "PreCompact", "PostCompact", "PreModelSwitch", "PostModelSwitch", "Elicitation",
        "ElicitationResult", "SessionEnd",
    ]

    /// Handler types and the field each one needs [V `hooks`].
    static let requiredField: [String: String?] = [
        "command": "command", "http": "url", "mcp_tool": nil, "prompt": "prompt", "agent": nil,
    ]

    /// Programs that take the script as their first argument, so the script itself need not be executable.
    static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "fish", "python", "python3", "node", "deno", "bun", "ruby", "perl", "php", "osascript",
    ]

    public struct Context: Sendable {
        public let home: String
        /// `$CLAUDE_PROJECT_DIR`, when the hook belongs to a known project.
        public let projectDir: String?
        /// `${CLAUDE_PLUGIN_ROOT}`, for a plugin's hook.
        public let pluginRoot: String?
        /// Asked whether a file exists and can run. Not limited to the scan roots: scripts often live elsewhere.
        public let probe: any ReadonlyFileSystem

        public init(home: String, projectDir: String?, pluginRoot: String?, probe: any ReadonlyFileSystem) {
            self.home = home
            self.projectDir = projectDir
            self.pluginRoot = pluginRoot
            self.probe = probe
        }
    }

    public static func check(event: String, matcher: String?, handler: JSONValue, context: Context) -> [Problem] {
        var problems: [Problem] = []
        if !events.contains(event) {
            problems.append(Problem(.error, "Unknown hook event: \(event)"))
        }
        if let matcher, !matcher.isEmpty, matcher != "*", (try? NSRegularExpression(pattern: matcher)) == nil {
            problems.append(Problem(.error, "The matcher is not a valid pattern: \(matcher)"))
        }
        let type = handler["type"]?.stringValue ?? "command"
        guard let field = requiredField[type] else {
            problems.append(Problem(.error, "Unknown hook type: \(type)"))
            return problems
        }
        if let field, (handler[field]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append(Problem(.error, "The \(type) hook has no \(field)"))
        }
        if let timeout = handler["timeout"] {
            switch timeout {
            case .number(let seconds) where seconds > 0: break
            default: problems.append(Problem(.warning, "The timeout should be a positive number of seconds"))
            }
        }
        if type == "command", let command = handler["command"]?.stringValue {
            problems += script(in: command, context: context)
        }
        return problems
    }

    /// What a command line may show: the program, or an interpreter and its script, then `…` for anything after.
    /// Arguments can hold a secret, so they are never shown (Review sheet, `claw plan`).
    public static func shownCommand(_ command: String) -> String {
        let words = CommandWords.split(command)
        guard let first = words.first else { return command.isEmpty ? command : "…" }
        var shown = [first]
        if interpreters.contains((first as NSString).lastPathComponent),
            let script = words.dropFirst().first(where: { !$0.hasPrefix("-") })
        {
            shown.append(script)
        }
        let text = shown.joined(separator: " ")
        return text == command.trimmingCharacters(in: .whitespaces) ? text : text + " …"
    }

    /// The program, or the script an interpreter is given. Bare names are found through `PATH` at run time, and
    /// paths with variables Claw cannot resolve are left alone: neither is reported.
    private static func script(in command: String, context: Context) -> [Problem] {
        let words = CommandWords.split(command)
        guard let first = words.first else { return [] }
        var candidate = first
        var mustRun = true
        if interpreters.contains((first as NSString).lastPathComponent) {
            guard let argument = words.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return [] }
            candidate = argument
            mustRun = false
        }
        guard let path = resolve(candidate, context: context), path.hasPrefix("/") else { return [] }
        let shown =
            path == context.home || path.hasPrefix(context.home + "/") ? "~" + path.dropFirst(context.home.count) : path
        guard context.probe.fileExists(path) else { return [Problem(.error, "Script not found: \(shown)")] }
        if mustRun, !context.probe.isExecutable(path) {
            return [Problem(.warning, "Script is not executable: \(shown)")]
        }
        return []
    }

    private static func resolve(_ word: String, context: Context) -> String? {
        var text = word
        if text == "~" || text.hasPrefix("~/") { text = context.home + text.dropFirst() }
        let variables: [(String, String?)] = [
            ("HOME", context.home), ("CLAUDE_PROJECT_DIR", context.projectDir),
            ("CLAUDE_PLUGIN_ROOT", context.pluginRoot),
        ]
        for (name, value) in variables {
            for form in ["${\(name)}", "$\(name)"] where text.contains(form) {
                guard let value else { return nil }
                text = text.replacingOccurrences(of: form, with: value)
            }
        }
        return text.contains("$") ? nil : text
    }
}

/// Splits a command line into words the way a shell would for plain quoting: single and double quotes group,
/// a backslash escapes, and the first `;`, `&`, `|`, `<` or `>` ends it. Enough to find the program; nothing
/// here runs a shell.
enum CommandWords {
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var inWord = false
        loop: for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
                inWord = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                inWord = true
            } else if character == " " || character == "\t" {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else if ";&|<>".contains(character) {
                break loop
            } else {
                current.append(character)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}
