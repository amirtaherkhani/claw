import ClefCore
import Foundation

let usage = """
    clef \(ClefVersion.string): read-only scan of Claude Code configuration

    Usage:
      clef scan [--json] [--project <path>]... [--folder <path>] [--no-cli]
      clef version
      clef help

    Options:
      --json             Print the full scan result as JSON (secrets are never included)
      --project <path>   Also read this project's .claude/ folder (repeatable)
      --folder <path>    Scan one project folder instead of this Mac
      --no-cli           Do not run the claude CLI (plugins then come from settings only)
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("clef: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

func absolute(_ path: String) -> String {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL.path
}

struct ScanOptions {
    var json = false
    var projects: [String] = []
    var folder: String?
    var useCLI = true
}

func parseScanOptions(_ args: ArraySlice<String>) -> ScanOptions {
    var options = ScanOptions()
    var rest = args
    while let arg = rest.popFirst() {
        switch arg {
        case "--json": options.json = true
        case "--no-cli": options.useCLI = false
        case "--project":
            guard let value = rest.popFirst() else { fail("--project needs a path") }
            options.projects.append(absolute(value))
        case "--folder":
            guard let value = rest.popFirst() else { fail("--folder needs a path") }
            options.folder = absolute(value)
        default: fail("unknown option \(arg)")
        }
    }
    return options
}

func printText(_ result: ScanResult) {
    let titles: [Bucket: String] = [.yours: "Yours", .readonly: "Read-only", .attention: "Needs attention"]
    print("Clef scan of \(result.target.path ?? "this Mac")\(result.partial ? " (partial)" : "")")
    if let version = result.claudeCodeVersion { print("Claude Code \(version)") }
    for bucket in Bucket.allCases {
        let items = result.items.filter { $0.bucket == bucket }
        guard !items.isEmpty else { continue }
        print("\n\(titles[bucket] ?? bucket.rawValue) (\(items.count))")
        for item in items {
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

func runScan(_ options: ScanOptions) async {
    let base = ClaudeEnvironment.current()
    let projects = options.folder.map { [$0] } ?? options.projects
    let environment = ClaudeEnvironment(
        home: base.home, configDir: base.configDir, pluginsDir: base.pluginsDir,
        managedDir: base.managedDir, projects: projects)
    let fs = LocalFileSystem()
    var cli: ClaudeCLI?
    if options.useCLI,
        let path = ClaudeCLI.locate(environment: ProcessInfo.processInfo.environment, home: base.home, fileSystem: fs)
    {
        cli = ClaudeCLI(executable: path)
    }
    let scanner = Scanner(
        environment: environment, target: options.folder.map(ScanTarget.folder) ?? .mac,
        fileSystem: fs, cli: cli)
    let result = await scanner.scan()

    guard options.json else {
        printText(result)
        return
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    do {
        FileHandle.standardOutput.write(try encoder.encode(result))
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("clef: cannot encode result: \(error)\n".utf8))
        exit(1)
    }
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "scan":
    await runScan(parseScanOptions(arguments.dropFirst()))
case "version", "--version":
    print("clef \(ClefVersion.string)")
case "help", "--help", "-h", nil:
    print(usage)
default:
    fail("unknown command \(arguments.first ?? "")")
}
