import ClawCore
import Foundation

let usage = """
    claw \(ClawVersion.string): read-only view of your Claude Code configuration

    Usage:
      claw scan [options]                 Scan and print items grouped by owner
      claw list [options]                 Same scan as a compact list (filter with --concept, --bucket)
      claw projects [list]                Projects Claw knows (registered and found in ~/.claude.json)
      claw projects add <path>            Register a project folder (stored by Claw, not by Claude Code)
      claw projects remove <path>         Unregister a project folder
      claw version | help

    Scan options:
      --json               Print JSON (secret values are never included)
      --project <path>     Also read this project (repeatable)
      --all-projects       Also read every registered and discovered project
      --folder <path>      Scan one project folder instead of this Mac
      --concept <name>     Only plugins|skills|commands|rules|agents|mcp|hooks
      --bucket <name>      Only yours|readonly|attention
      --no-cli             Do not run the claude CLI (plugins then come from settings only)
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("claw: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

func absolute(_ path: String) -> String {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL.path
}

func writeJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    do {
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("claw: cannot encode output: \(error)\n".utf8))
        exit(1)
    }
}

let base = ClaudeEnvironment.current()
let fs = LocalFileSystem()
let registry = ProjectRegistry(file: ProjectRegistry.defaultFile(home: base.home))

/// Registered projects plus the ones Claude Code already knows, without duplicates.
func knownProjects() -> [String] {
    let registered = registry.load(fileSystem: fs).0.map(\.path)
    let discovered = ProjectDiscovery(fileSystem: fs).knownProjects(environment: base)
    return ProjectRegistry.deduplicated(registered + discovered, fileSystem: fs)
}

// MARK: scan and list

struct ScanOptions {
    var json = false
    var projects: [String] = []
    var allProjects = false
    var folder: String?
    var useCLI = true
    var concept: Concept?
    var bucket: Bucket?
}

func parseScanOptions(_ args: ArraySlice<String>) -> ScanOptions {
    var options = ScanOptions()
    var rest = args
    func value(_ flag: String) -> String {
        guard let value = rest.popFirst() else { fail("\(flag) needs a value") }
        return value
    }
    while let arg = rest.popFirst() {
        switch arg {
        case "--json": options.json = true
        case "--no-cli": options.useCLI = false
        case "--all-projects": options.allProjects = true
        case "--project": options.projects.append(absolute(value(arg)))
        case "--folder": options.folder = absolute(value(arg))
        case "--concept":
            let raw = value(arg)
            guard let concept = Concept(rawValue: raw) else { fail("unknown concept \(raw)") }
            options.concept = concept
        case "--bucket":
            let raw = value(arg)
            guard let bucket = Bucket(rawValue: raw) else { fail("unknown bucket \(raw)") }
            options.bucket = bucket
        default: fail("unknown option \(arg)")
        }
    }
    return options
}

func scan(_ options: ScanOptions) async -> ScanResult {
    var projects = options.projects
    if options.allProjects { projects += knownProjects() }
    let environment = ClaudeEnvironment(
        home: base.home, configDir: base.configDir, pluginsDir: base.pluginsDir, managedDir: base.managedDir,
        projects: options.folder.map { [$0] } ?? ProjectRegistry.deduplicated(projects, fileSystem: fs))
    var cli: ClaudeCLI?
    if options.useCLI,
        let path = ClaudeCLI.locate(environment: ProcessInfo.processInfo.environment, home: base.home, fileSystem: fs)
    {
        cli = ClaudeCLI(executable: path)
    }
    let showProgress = !options.json && isatty(STDERR_FILENO) == 1
    let scanner = ConfigScanner(
        environment: environment, target: options.folder.map(ScanTarget.folder) ?? .mac, fileSystem: fs, cli: cli)
    let result = await scanner.scan { progress in
        guard showProgress else { return }
        let line = progress.step == .done ? "\r\u{1B}[K" : "\r\u{1B}[K\(progress.step.label)…"
        FileHandle.standardError.write(Data(line.utf8))
    }
    return result
}

func filtered(_ result: ScanResult, _ options: ScanOptions) -> [Item] {
    result.items.filter {
        (options.concept == nil || $0.concept == options.concept) && (options.bucket == nil || $0.bucket == options.bucket)
    }
}

let bucketTitles: [Bucket: String] = [.yours: "Yours", .readonly: "Read-only", .attention: "Needs attention"]

func printGrouped(_ result: ScanResult, items: [Item]) {
    print("Claw scan of \(result.target.path ?? "this Mac")\(result.partial ? " (partial)" : "")")
    if let version = result.claudeCodeVersion { print("Claude Code \(version)") }
    for bucket in Bucket.allCases {
        let group = items.filter { $0.bucket == bucket }
        guard !group.isEmpty else { continue }
        print("\n\(bucketTitles[bucket] ?? bucket.rawValue) (\(group.count))")
        for item in group {
            let concept = item.concept.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
            print("  [\(item.enabled ? "on " : "off")] \(concept) \(item.name)  \(item.classification.rule)  \(item.location)")
        }
    }
    if !result.problems.isEmpty {
        print("\nProblems (\(result.problems.count))")
        for problem in result.problems {
            print("  \(problem.severity.rawValue): \(problem.message)\(problem.file.map { " [\($0)]" } ?? "")")
        }
    }
}

func printList(_ items: [Item]) {
    for item in items {
        let state = item.enabled ? "on " : "off"
        let concept = item.concept.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
        let owner = (bucketTitles[item.bucket] ?? "").padding(toLength: 15, withPad: " ", startingAt: 0)
        print("\(state)  \(concept)  \(owner)  \(item.name)")
    }
    print("\(items.count) items")
}

// MARK: projects

func runProjects(_ args: ArraySlice<String>) throws {
    var rest = args
    let command = rest.popFirst() ?? "list"
    switch command {
    case "list", "--json":
        let (registered, problems) = registry.load(fileSystem: fs)
        let discovered = ProjectDiscovery(fileSystem: fs).knownProjects(environment: base)
        if command == "--json" || rest.contains("--json") {
            struct Output: Encodable {
                let registered: [RegisteredProject]
                let discovered: [String]
                let registryFile: String
            }
            writeJSON(Output(registered: registered, discovered: discovered, registryFile: registry.file))
            return
        }
        print("Registered (\(registered.count)) in \(registry.file)")
        for project in registered { print("  \(project.path)") }
        print("Found in ~/.claude.json (\(discovered.count))")
        for path in discovered { print("  \(path)") }
        for problem in problems { print("\(problem.severity.rawValue): \(problem.message)") }
    case "add", "remove":
        guard let raw = rest.popFirst() else { fail("projects \(command) needs a path") }
        let path = absolute(raw)
        let (current, problems) = registry.load(fileSystem: fs)
        guard problems.isEmpty else { fail("the project list is unreadable; fix or move \(registry.file) first") }
        if command == "add" {
            guard fs.isDirectory(path) else { fail("not a folder: \(path)") }
            let updated = ProjectRegistry.adding(path, to: current, fileSystem: fs)
            try registry.save(updated)
            print(updated.count == current.count ? "Already registered: \(path)" : "Registered \(path)")
        } else {
            let updated = ProjectRegistry.removing(path, from: current, fileSystem: fs)
            try registry.save(updated)
            print(updated.count == current.count ? "Not registered: \(path)" : "Removed \(path) (no files were touched)")
        }
    default:
        fail("unknown projects command \(command)")
    }
}

// MARK: main

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "scan", "list":
    let options = parseScanOptions(arguments.dropFirst())
    let result = await scan(options)
    let items = filtered(result, options)
    if options.json {
        writeJSON(
            options.concept == nil && options.bucket == nil
                ? result
                : ScanResult(
                    target: result.target, startedAt: result.startedAt, finishedAt: result.finishedAt,
                    partial: result.partial, claudeCodeVersion: result.claudeCodeVersion, items: items,
                    problems: result.problems))
    } else if arguments.first == "list" {
        printList(items)
    } else {
        printGrouped(result, items: items)
    }
case "projects":
    do {
        try runProjects(arguments.dropFirst())
    } catch {
        FileHandle.standardError.write(Data("claw: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
case "version", "--version":
    print("claw \(ClawVersion.string)")
case "help", "--help", "-h", nil:
    print(usage)
default:
    fail("unknown command \(arguments.first ?? "")")
}
