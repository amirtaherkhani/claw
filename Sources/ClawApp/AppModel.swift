import AppKit
import ClawCore
import Foundation
import Observation

/// App state. Everything here runs on the main actor; scanning and file reads run off it.
/// Claw writes only its own project list here; changes to Claude's configuration are queued for review
/// and applied by the write pipeline (milestone M2).
@MainActor
@Observable
final class AppModel {
    enum Destination: Hashable {
        case overview, scan, projects, history
        case concept(Concept)
    }

    // Navigation and sheets
    var destination: Destination? = .overview
    var detailItem: Item?
    var showReview = false
    var showAddPlugin = false
    var addProjectPath: String?
    private(set) var toast: String?

    // Scan
    private(set) var result: ScanResult?
    private(set) var progress: ScanProgress?
    private(set) var scanTarget: ScanTarget = .mac
    private(set) var modified: [String: Date] = [:]
    private var scanTask: Task<Void, Never>?
    var isScanning: Bool { scanTask != nil }

    // Projects and scope
    private(set) var registered: [RegisteredProject] = []
    private(set) var discovered: [String] = []
    private(set) var activeProject: String?
    var scope: SettingsScope = .user

    // Changes
    var queue = ChangeQueue()

    let environment: ClaudeEnvironment
    let fileSystem = LocalFileSystem()
    private let registry: ProjectRegistry
    private static let activeProjectKey = "activeProject"

    init() {
        environment = ClaudeEnvironment.current()
        registry = ProjectRegistry(file: ProjectRegistry.defaultFile(home: environment.home))
        loadProjects()
        if let saved = UserDefaults.standard.string(forKey: Self.activeProjectKey), allProjects.contains(saved) {
            activeProject = saved
        }
    }

    var home: String { environment.home }

    // MARK: Derived values

    var items: [Item] { result?.items ?? [] }
    var stats: OverviewStats { OverviewStats(items: items, problems: result?.problems.count ?? 0) }
    var allProjects: [String] {
        ProjectRegistry.deduplicated(registered.map(\.path) + discovered, fileSystem: fileSystem)
    }
    var writeScope: WriteScope? { WriteScope.resolve(scope, environment: environment, activeProject: activeProject) }
    var writeScopeLabel: String {
        writeScope.map { ItemPresentation.abbreviate($0.file, home: home) } ?? "choose an active project first"
    }

    func items(concept: Concept?, bucket: Bucket?) -> [Item] {
        items.filter { (concept == nil || $0.concept == concept) && (bucket == nil || $0.bucket == bucket) }
    }

    func count(_ concept: Concept) -> Int { items.lazy.filter { $0.concept == concept }.count }

    func modifiedDate(_ item: Item) -> Date? { modified[ItemPresentation.file(item)] }

    func isRegistered(_ path: String) -> Bool {
        registered.contains { fileSystem.resolvingSymlinks($0.path) == fileSystem.resolvingSymlinks(path) }
    }

    // MARK: Scan

    /// Scans this Mac (plus every known project) or one folder. Stop keeps partial results.
    func startScan(target: ScanTarget = .mac) {
        guard scanTask == nil else { return }
        loadProjects()
        scanTarget = target
        let projects = target.kind == .folder ? [target.path ?? ""] : allProjects
        let env = ClaudeEnvironment(
            home: environment.home, configDir: environment.configDir, pluginsDir: environment.pluginsDir,
            managedDir: environment.managedDir, projects: projects)
        // GUI apps get a minimal PATH; `locate` also checks the usual install folders.
        let cli = ClaudeCLI.locate(
            environment: ProcessInfo.processInfo.environment, home: environment.home, fileSystem: fileSystem
        ).map { ClaudeCLI(executable: $0) }
        let scanner = ConfigScanner(environment: env, target: target, fileSystem: fileSystem, cli: cli)

        progress = ScanProgress(step: .settings, itemCount: 0)
        scanTask = Task {
            // The model lives as long as the app, so a strong capture is fine here.
            let (result, modified) = await Self.run(scanner) { update in
                Task { @MainActor in self.progress = update }
            }
            self.result = result
            self.modified = modified
            self.progress = nil
            self.scanTask = nil
            self.queue = Self.prune(self.queue, items: result.items)
            if result.partial { self.show("Scan finished with partial results") }
        }
    }

    func stopScan() { scanTask?.cancel() }

    nonisolated private static func run(
        _ scanner: ConfigScanner, progress: @escaping @Sendable (ScanProgress) -> Void
    ) async -> (ScanResult, [String: Date]) {
        let result = await scanner.scan(progress: progress)
        let fs = LocalFileSystem()
        var dates: [String: Date] = [:]
        for item in result.items {
            let file = ItemPresentation.file(item)
            if dates[file] == nil, let date = fs.modificationDate(file) { dates[file] = date }
        }
        return (result, dates)
    }

    /// Drops queued changes whose item no longer exists after a rescan.
    private static func prune(_ queue: ChangeQueue, items: [Item]) -> ChangeQueue {
        let ids = Set(items.map(\.id))
        var copy = queue
        for change in queue.changes where !ids.contains(change.itemId) { copy.discard(change) }
        return copy
    }

    // MARK: Changes

    func toggle(_ item: Item) {
        if let message = queue.toggle(item, writeScope: writeScope, home: home) { show(message) }
    }

    func toggleRemoval(_ item: Item) {
        if let message = queue.toggleRemoval(item, home: home) { show(message) }
    }

    func toggle(_ selection: [Item], enable: Bool) {
        var skipped = 0
        for item in selection where queue.effectiveEnabled(item) != enable {
            if queue.toggle(item, writeScope: writeScope, home: home) != nil { skipped += 1 }
        }
        if skipped > 0 { show("Skipped \(ItemPresentation.counted(skipped, "read-only item"))") }
    }

    func remove(_ selection: [Item]) {
        var skipped = 0
        for item in selection where !queue.isQueuedForRemoval(item) {
            if queue.toggleRemoval(item, home: home) != nil { skipped += 1 }
        }
        if skipped > 0 { show("Skipped \(ItemPresentation.counted(skipped, "item")) that cannot be removed here") }
    }

    // MARK: Projects

    func loadProjects() {
        let (list, problems) = registry.load(fileSystem: fileSystem)
        registered = list
        discovered = ProjectDiscovery(fileSystem: fileSystem).knownProjects(environment: environment)
        if let problem = problems.first { show(problem.message) }
    }

    func addProject(_ path: String) {
        let updated = ProjectRegistry.adding(path, to: registered, fileSystem: fileSystem)
        do {
            try registry.save(updated)
            registered = updated
            if activeProject == nil { setActiveProject(path) }
            show("Added \(URL(fileURLWithPath: path).lastPathComponent)")
        } catch {
            show("Could not save the project list: \(error.localizedDescription)")
        }
    }

    func removeProject(_ path: String) {
        let updated = ProjectRegistry.removing(path, from: registered, fileSystem: fileSystem)
        do {
            try registry.save(updated)
            registered = updated
            if activeProject == path { setActiveProject(nil) }
            show("Stopped managing \(URL(fileURLWithPath: path).lastPathComponent). No files were touched.")
        } catch {
            show("Could not save the project list: \(error.localizedDescription)")
        }
    }

    func setActiveProject(_ path: String?) {
        activeProject = path
        UserDefaults.standard.set(path, forKey: Self.activeProjectKey)
        if path == nil && scope != .user { scope = .user }
    }

    // MARK: System

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Opens the file in the user's default editor (Edit source…).
    func openInEditor(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toast == message { toast = nil }
        }
    }
}
