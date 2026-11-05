import Foundation

/// One line of `history.jsonl`: one Apply or Restore. No file contents and no secret values
/// (TECHNICAL-DESIGN section 9.4), so a caller's title must not quote a command or a URL.
public struct HistoryEntry: Codable, Sendable, Equatable {
    public let id: String
    public let time: String
    public let title: String
    public let files: [String]
    public let backupId: String
    public let result: BackupManifest.Status

    public init(
        id: String, time: String, title: String, files: [String], backupId: String, result: BackupManifest.Status
    ) {
        self.id = id
        self.time = time
        self.title = title
        self.files = files
        self.backupId = backupId
        self.result = result
    }
}

/// Append-only log next to the backups. A crash can only tear the last line, which reading reports and skips.
public struct HistoryLog: Sendable {
    public let file: String

    public func append(_ entry: HistoryEntry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(entry)
        line.append(0x0A)
        try PrivateFiles.makeFolder((file as NSString).deletingLastPathComponent)
        if let last = try? Data(contentsOf: URL(fileURLWithPath: file)).last, last != 0x0A {
            line.insert(0x0A, at: line.startIndex)
        }
        let descriptor = open(file, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o600))
        guard descriptor >= 0 else { throw BackupError(reason: "cannot open \(file)") }
        defer { close(descriptor) }
        let written = line.withUnsafeBytes { Foundation.write(descriptor, $0.baseAddress, $0.count) }
        guard written == line.count, fsync(descriptor) == 0 else { throw BackupError(reason: "cannot write \(file)") }
    }

    /// Entries oldest first. A damaged line becomes a problem instead of hiding the others.
    public func entries() throws -> (entries: [HistoryEntry], problems: [Problem]) {
        guard FileManager.default.fileExists(atPath: file) else { return ([], []) }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: file))
        } catch {
            throw BackupError(reason: "cannot read \(file)")
        }
        var entries: [HistoryEntry] = []
        var problems: [Problem] = []
        for line in data.split(separator: 0x0A) {
            if let entry = try? JSONDecoder().decode(HistoryEntry.self, from: Data(line)) {
                entries.append(entry)
            } else {
                problems.append(Problem(.warning, "Skipped a damaged history line", file: file))
            }
        }
        return (entries, problems)
    }
}

extension BackupStore {
    public var history: HistoryLog { HistoryLog(file: joinPath(root, "history.jsonl")) }
}
