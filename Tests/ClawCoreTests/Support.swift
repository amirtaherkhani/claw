import Foundation

@testable import ClawCore

/// In-memory, read-only file system for tests. Directories are implied by file paths.
struct MemoryFileSystem: ReadonlyFileSystem {
    let files: [String: Data]

    init(_ files: [String: String]) {
        self.files = files.mapValues { Data($0.utf8) }
    }

    func readFile(_ path: String) throws -> Data? { files[path] }

    func contentsOfDirectory(_ path: String) throws -> [String]? {
        guard isDirectory(path) else { return nil }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let names = files.keys.filter { $0.hasPrefix(prefix) }.compactMap { key -> String? in
            key.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
        }
        return Array(Set(names)).sorted()
    }

    func isDirectory(_ path: String) -> Bool {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return files.keys.contains { $0.hasPrefix(prefix) }
    }

    func fileExists(_ path: String) -> Bool { files[path] != nil || isDirectory(path) }

    func resolvingSymlinks(_ path: String) -> String { path }
}

/// Returns canned results keyed by the joined argument list.
struct FakeRunner: CommandRunner {
    let responses: [String: CommandResult]

    func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> CommandResult {
        guard let result = responses[arguments.joined(separator: " ")] else { throw CommandError.notFound }
        return result
    }
}

func ok(_ text: String) -> CommandResult { CommandResult(exitCode: 0, stdout: Data(text.utf8)) }
