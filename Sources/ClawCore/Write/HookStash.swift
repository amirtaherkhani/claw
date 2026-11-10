import Foundation

/// A hook taken out of a settings file (TECHNICAL-DESIGN section 9.5). `handler` may hold a secret in its
/// command: never log it, and mask it in the UI.
public struct HookStashEntry: Codable, Sendable, Equatable {
    public struct Position: Codable, Sendable, Equatable {
        public let groupIndex: Int
        public let handlerIndex: Int
    }

    public var schema = 1
    public let id: String
    public let sourceFile: String
    public let event: String
    public let matcher: String?
    public let handler: JSONValue
    /// The handler as written, so restoring keeps its key order and spacing.
    public let handlerText: String
    /// The whole group as written, when removing this handler removed the group too.
    public let groupText: String?
    public let position: Position
    public let stashedAt: String
}

/// `~/Library/Application Support/Claw/stash/`, folder 0700 and files 0600 (`NFR-SEC-4`).
public struct HookStash: Sendable {
    public let root: String

    init(root: String) { self.root = root }

    public init(environment: ClaudeEnvironment) {
        root = environment.hookStashDir
    }

    /// `enabledBy` of a hook listed from the stash: "Off (turned off by Claw)" (FR-F15-4).
    public static let turnedOffBy = "Claw"

    public func put(_ entry: HookStashEntry) throws {
        try PrivateFiles.makeFolder(root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicWrite.write(try encoder.encode(entry), to: try file(entry.id), expectedSHA256: nil)
    }

    public func entries() throws -> [HookStashEntry] {
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: root).sorted().filter { $0.hasSuffix(".json") }.map {
            let data = try Data(contentsOf: URL(fileURLWithPath: joinPath(root, $0)))
            try StrictJSON.validate(data)
            return try JSONDecoder().decode(HookStashEntry.self, from: data)
        }
    }

    /// Moves an entry to `taken/`: a stash entry can hold the only copy of a command, so it is never deleted.
    public func take(_ id: String) throws {
        let source = try file(id)
        let folder = joinPath(root, "taken")
        try PrivateFiles.makeFolder(folder)
        guard Disk.rename(source, joinPath(folder, "\(id).json")) == 0 else {
            throw BackupError(reason: "cannot take \(id) from the stash")
        }
    }

    private func file(_ id: String) throws -> String {
        guard NameValidator.isValidName(id) else { throw BackupError(reason: "not a stash id: \(id)") }
        return joinPath(root, "\(id).json")
    }
}
