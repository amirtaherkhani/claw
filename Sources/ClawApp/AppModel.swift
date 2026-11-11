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
    /// What Apply would write for the queue, planned off the main actor. `nil` while planning.
    private(set) var review: Review?

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
        claudeFound =
            ClaudeCLI.locate(environment: ProcessInfo.processInfo.environment, home: home, fileSystem: fileSystem) != nil
    }

    var home: String { environment.home }

    /// Whether Claude Code's `claude` command was found. With it, changes it has a command for go through it
    /// (`CommandCatalog.standard`); without it, Claw makes every change it can itself.
    private(set) var claudeFound = false
    var commands: CommandCatalog { claudeFound ? .standard : .none }

    // MARK: Derived values

    var items: [Item] { result?.items ?? [] }
    var stats: OverviewStats { OverviewStats(items: items, problems: result?.problems.count ?? 0) }
    var allProjects: [String] {
        ProjectRegistry.deduplicated(registered.map(\.path) + discovered, fileSystem: fileSystem)
    }
    var writeScope: WriteScope? { WriteScope.resolve(scope, environment: environment, activeProject: activeProject) }
    var writeScopeLabel: String {
        writeScope.map { ItemPresentation.abbreviate($0.file, home: home) } ?? String(localized: "choose an active project first")
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
        let env = environment.with(projects: projects)
        // GUI apps get a minimal PATH; `locate` also checks the usual install folders.
        let cli = ClaudeCLI.locate(
            environment: ProcessInfo.processInfo.environment, home: environment.home, fileSystem: fileSystem
        ).map { ClaudeCLI(executable: $0, environment: env) }
        claudeFound = cli != nil
        let scanner = ConfigScanner(environment: env, target: target, fileSystem: fileSystem, cli: cli)

        progress = ScanProgress(step: .settings, itemCount: 0)
        scanTask = Task {
            // The model lives as long as the app, so a strong capture is fine here.
            let (result, modified) = await Self.run(scanner) { update in
                Task { @MainActor in self.progress = update }
            }
            let outcome = ScanOutcome(
                result: result, projects: projects, stopped: Task.isCancelled, previous: self.result, queue: self.queue)
            if outcome.replacesResult {
                self.result = result
                self.modified = modified
            }
            self.progress = nil
            self.scanTask = nil
            self.queue = outcome.queue
            if let message = outcome.message { self.show(message) }
        }
    }

    func stopScan() { scanTask?.cancel() }

    nonisolated private static func run(
        _ scanner: ConfigScanner, progress: @escaping @Sendable (ScanProgress) -> Void
    ) async -> (ScanResult, [String: Date]) {
        let result = await scanner.scan(progress: progress)
        return (result, await scanner.modificationDates(for: result.items))
    }

    // MARK: Changes

    func toggle(_ item: Item) {
        if let message = queue.toggle(item, writeScope: writeScope, home: home) { show(message) }
    }

    /// Plans the queue for the Review sheet. Planning reads files and writes nothing; a newer queue wins.
    func refreshReview() async {
        let queue = self.queue
        let scope = writeScope
        let project = activeProject
        review = nil
        let planned = await Review.build(
            queue: queue, items: items, environment: environment, writeScope: scope, activeProject: project,
            commands: commands)
        guard !Task.isCancelled, queue == self.queue, scope == writeScope, project == activeProject else { return }
        review = planned
    }

    func toggleRemoval(_ item: Item) {
        if let message = queue.toggleRemoval(item, home: home) { show(message) }
    }

    func toggle(_ selection: [Item], enable: Bool) {
        var skipped = 0
        for item in selection where queue.effectiveEnabled(item) != enable {
            if queue.toggle(item, writeScope: writeScope, home: home) != nil { skipped += 1 }
        }
        if skipped > 0 { show(String(localized: "Skipped \(ItemPresentation.counted(skipped, "read-only item"))")) }
    }

    func remove(_ selection: [Item]) {
        var skipped = 0
        for item in selection where !queue.isQueuedForRemoval(item) {
            if queue.toggleRemoval(item, home: home) != nil { skipped += 1 }
        }
        if skipped > 0 {
            show(String(localized: "Skipped \(ItemPresentation.counted(skipped, "item")) that cannot be removed here"))
        }
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
            show(String(localized: "Added \(URL(fileURLWithPath: path).lastPathComponent)"))
        } catch {
            show(String(localized: "Could not save the project list: \(error.localizedDescription)"))
        }
    }

    func removeProject(_ path: String) {
        let updated = ProjectRegistry.removing(path, from: registered, fileSystem: fileSystem)
        do {
            try registry.save(updated)
            registered = updated
            if activeProject == path { setActiveProject(nil) }
            show(String(localized: "Stopped managing \(URL(fileURLWithPath: path).lastPathComponent). No files were touched."))
        } catch {
            show(String(localized: "Could not save the project list: \(error.localizedDescription)"))
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
