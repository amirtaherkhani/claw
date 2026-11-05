import Foundation

/// Finds folders with their own `.claude/` under a scanned folder (TECHNICAL-DESIGN section 8.2). It stays bounded
/// so that a folder scan never turns into a crawl of the disk.
public struct NestedProjectWalk: Sendable {
    public struct Result: Sendable, Equatable {
        public let projects: [String]
        /// A limit was reached, so there may be more.
        public let truncated: Bool
    }

    static let ignored: Set<String> = ["node_modules", "dist", "build", "target"]

    private let fs: any ReadonlyFileSystem
    private let maxDepth: Int
    private let maxDirectories: Int
    private let timeLimit: Duration

    public init(
        fileSystem: any ReadonlyFileSystem, maxDepth: Int = 4, maxDirectories: Int = 5000,
        timeLimit: Duration = .seconds(2)
    ) {
        self.fs = fileSystem
        self.maxDepth = maxDepth
        self.maxDirectories = maxDirectories
        self.timeLimit = timeLimit
    }

    /// Breadth first, so a limit cuts the deepest folders. Hidden folders are skipped, which covers `.git` and `.next`.
    public func find(under root: String) -> Result {
        let clock = ContinuousClock()
        let start = clock.now
        var found: [String] = []
        var queue = [(path: root, depth: 0)]
        var next = 0

        while next < queue.count {
            guard next < maxDirectories, start.duration(to: clock.now) < timeLimit else {
                return Result(projects: found.sorted(), truncated: true)
            }
            let (folder, depth) = queue[next]
            next += 1
            if depth > 0, fs.isDirectory(joinPath(folder, ".claude")) { found.append(folder) }
            guard depth < maxDepth, let entries = try? fs.contentsOfDirectory(folder) else { continue }
            for entry in entries where !entry.hasPrefix(".") && !Self.ignored.contains(entry) {
                let path = joinPath(folder, entry)
                if fs.isDirectory(path) { queue.append((path, depth + 1)) }
            }
        }
        return Result(projects: found.sorted(), truncated: false)
    }
}
