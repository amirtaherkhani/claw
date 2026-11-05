import Foundation

/// Keeps a scan inside its roots (FR-F02-5, TECHNICAL-DESIGN section 8.3). A path is read only when its real
/// location is inside the root it was asked under. A path under no root is refused, so a new reader cannot
/// widen the scan by accident. The one exception is the user's own tooling: dotfile and skill managers link files
/// and folders under the config folder to places in the home folder. Refusals look like missing files, and
/// `problems` reports them.
final class ContainedFileSystem: ReadonlyFileSystem, @unchecked Sendable {
    private struct Root {
        let path: String
        let real: String
    }

    private let base: any ReadonlyFileSystem
    private let configDir: String
    private let realHome: String
    private let lock = NSLock()
    private var roots: [Root] = []
    private var refused = Set<String>()

    init(_ base: any ReadonlyFileSystem, environment: ClaudeEnvironment) {
        self.base = base
        configDir = environment.configDir
        realHome = base.resolvingSymlinks(environment.home)
        addRoots(
            [environment.configDir, environment.pluginsDir, environment.managedDir, environment.claudeJsonFile]
                + environment.projects)
    }

    /// Roots known only part way through a scan: marketplace and plugin folders.
    func addRoots(_ paths: [String]) {
        let added = paths.filter { !$0.isEmpty }.map { Root(path: $0, real: base.resolvingSymlinks($0)) }
        lock.withLock { roots += added }
    }

    /// One warning per refused path, in a stable order.
    var problems: [Problem] {
        lock.withLock { refused.sorted() }.map {
            Problem(.warning, "Skipped a symlink that leaves the scan root", file: $0)
        }
    }

    private func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    private func allows(_ path: String) -> Bool {
        let candidates = lock.withLock { roots }.filter { isInside(path, $0.path) }
        let real = base.resolvingSymlinks(path)
        if candidates.contains(where: { isInside(real, $0.real) }) { return true }
        if isInside(path, configDir), isInside(real, realHome) { return true }
        _ = lock.withLock { refused.insert(path) }
        return false
    }

    func readFile(_ path: String) throws -> Data? {
        allows(path) ? try base.readFile(path) : nil
    }

    func contentsOfDirectory(_ path: String) throws -> [String]? {
        allows(path) ? try base.contentsOfDirectory(path) : nil
    }

    func isDirectory(_ path: String) -> Bool { allows(path) && base.isDirectory(path) }

    func fileExists(_ path: String) -> Bool { allows(path) && base.fileExists(path) }

    func resolvingSymlinks(_ path: String) -> String { base.resolvingSymlinks(path) }

    func modificationDate(_ path: String) -> Date? { allows(path) ? base.modificationDate(path) : nil }
}
