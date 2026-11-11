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
    /// Counts finished scans, so a review planned on older items is planned again.
    private(set) var scanGeneration = 0
    private(set) var isApplying = false
    /// The last step Apply reached, while it runs.
    private(set) var applyStep: ApplyStep?
    /// What the last Apply did, until the Review sheet closes.
    private(set) var applyOutcome: ApplyOutcome?

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
        checkInterrupted()
    }

    // MARK: Recovery after a crash (M2.16)

    /// Changes a crash left behind; the first one is shown at start-up with Cancel and Continue, or OK.
    private(set) var interrupted: [InterruptedChange] = []
    var recoveryShown: Bool {
        get { !interrupted.isEmpty && !recovering }
        set { if !newValue, !recovering { interrupted.removeFirst(min(1, interrupted.count)) } }
    }
    private var recovering = false

    func checkInterrupted() {
        do {
            interrupted = try recoveryCommands().interrupted()
        } catch {
            show(String(localized: "Claw could not read its backups to check for an unfinished change."))
        }
    }

    func recover(_ change: InterruptedChange, _ choice: WriteCommands.RecoveryChoice) {
        recovering = true
        Task {
            let result = await (try? recoveryCommands())?.recover(id: change.id, choice: choice)
            recovering = false
            show(result.map { $0.output.split(separator: "\n").first.map(String.init) ?? "" } ?? "")
            checkInterrupted()
            startScan(target: scanTarget)
        }
    }

    private func recoveryCommands() throws -> WriteCommands {
        let env = environment
        let fileSystem = fileSystem
        let cli = ClaudeCLI.locate(
            environment: ProcessInfo.processInfo.environment, home: env.home, fileSystem: fileSystem
        ).map { ClaudeCLI(executable: $0, environment: env) }
        return WriteCommands(
            environment: env, fileSystem: fileSystem, store: try BackupStore(environment: env),
            stash: HookStash(environment: env), cli: cli, appVersion: ClawVersion.string, claudeVersion: nil,
            scan: { await ConfigScanner(environment: env, fileSystem: fileSystem, cli: cli).scan() })
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
                self.scanGeneration += 1
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

    /// Applies the reviewed queue through the write pipeline (backup first, rollback on any failure). An applied
    /// queue is cleared; anything else keeps it, so it can be reviewed and applied again. A scan follows any write.
    func apply() async {
        guard let review, review.canApply, !isApplying else { return }
        isApplying = true
        applyStep = nil
        applyOutcome = nil
        let environment = environment.with(projects: allProjects)
        let (queue, items, scope, project, home, commands) = (queue, items, writeScope, activeProject, home, commands)
        let outcome: ApplyOutcome
        do {
            let pipeline = try makePipeline(environment)
            outcome = await ApplyOutcome.run(
                review, pipeline: pipeline, home: home,
                replan: {
                    try Review.plans(
                        queue: queue, items: items,
                        planner: Planner(environment: environment, fileSystem: LocalFileSystem(), commands: commands),
                        writeScope: scope, activeProject: project, home: home)
                })
        } catch {
            outcome = ApplyOutcome.cannotStart(review, reason: "Cannot open the backup folder: \(error)")
        }
        applyOutcome = outcome
        applyStep = nil
        isApplying = false
        if outcome.kind == .applied { self.queue.clear() }
        if !outcome.wroteNothing { startScan(target: scanTarget) }
    }

    /// The write pipeline with the backup store, Claw's stash and `claude` when found. Its steps feed `applyStep`.
    private func makePipeline(_ environment: ClaudeEnvironment) throws -> ApplyPipeline {
        let cli = ClaudeCLI.locate(
            environment: ProcessInfo.processInfo.environment, home: home, fileSystem: fileSystem
        ).map { ClaudeCLI(executable: $0, environment: environment) }
        return ApplyPipeline(
            environment: environment, store: try BackupStore(environment: environment),
            stash: HookStash(environment: environment), cli: cli, appVersion: ClawVersion.string, claudeVersion: nil,
            progress: { step in Task { @MainActor in self.applyStep = step } })
    }

    // MARK: History and Restore (M4.4)

    private(set) var history: [HistoryRow] = []
    private(set) var historyProblems: [String] = []
    /// The Apply whose backup the Restore sheet shows.
    var restoring: HistoryRow?
    private(set) var restorePreview: RestorePreview?
    private(set) var restoreError: String?
    private(set) var restoreOutcome: ApplyOutcome?
    private(set) var isRestoring = false

    /// Reads `history.jsonl`; it holds one short line per Apply.
    func loadHistory() {
        do {
            (history, historyProblems) = HistoryList.rows(store: try BackupStore(environment: environment), home: home)
        } catch {
            (history, historyProblems) = ([], [String(localized: "Claw could not open its backup folder.")])
        }
    }

    /// Plans the restore of `restoring`, reading files only. `accept` names files to restore over later changes.
    func prepareRestore(accept: Set<String> = []) {
        guard let row = restoring else { return }
        restoreOutcome = nil
        do {
            restorePreview = try RestorePreview.make(
                id: row.id, accept: accept, store: try BackupStore(environment: environment),
                stash: HookStash(environment: environment), home: home)
            restoreError = nil
        } catch {
            restorePreview = nil
            restoreError = String(describing: error)
        }
    }

    /// Puts the backup back through the pipeline: a new backup first, then a History line of its own.
    func runRestore() async {
        guard let preview = restorePreview, preview.canRestore, !isRestoring else { return }
        isRestoring = true
        applyStep = nil
        let outcome: ApplyOutcome
        do {
            outcome = await RestorePreview.run(preview, pipeline: try makePipeline(environment), home: home)
        } catch {
            outcome = RestorePreview.cannotStart(preview, reason: "Cannot open the backup folder: \(error)")
        }
        restoreOutcome = outcome
        applyStep = nil
        isRestoring = false
        loadHistory()
        if !outcome.wroteNothing { startScan(target: scanTarget) }
    }

    func closeRestore() {
        restoring = nil
        restorePreview = nil
        restoreOutcome = nil
        restoreError = nil
    }

    /// Closes the Apply result; the review shows again.
    func dismissApplyOutcome() { applyOutcome = nil }

    /// A file changed since the scan: scan again, so the review is planned on what is there now.
    func rescanAfterStale() {
        applyOutcome = nil
        startScan(target: scanTarget)
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

    // MARK: Scope (M4.5)

    /// The scope waiting for a project: Project and Local write into the active project (FR-F13-2).
    var choosingProjectFor: SettingsScope?

    /// Where the switch writes now, and what that file means.
    var scopeTarget: ScopeRules.Target {
        ScopeRules.target(scope, environment: environment, activeProject: activeProject, home: home)
    }

    var mcpExplanation: [String] {
        ScopeRules.mcpExplanation(scope, environment: environment, activeProject: activeProject, home: home)
    }

    /// The switch was moved: switch, or ask for a project first.
    func requestScope(_ wanted: SettingsScope) {
        switch ScopeRules.request(wanted, activeProject: activeProject) {
        case .switchTo(let next): scope = next
        case .chooseProject(let next): choosingProjectFor = next
        }
    }

    /// A project was picked for the scope that asked for it.
    func chooseProject(_ path: String) {
        let wanted = choosingProjectFor
        setActiveProject(path)
        if let wanted { scope = wanted }
        choosingProjectFor = nil
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
