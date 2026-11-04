import ClawCore
import Foundation
import Observation

/// UI state for the read-only scan. All mutation happens on the main actor; the scan itself runs off it.
@MainActor
@Observable
final class ScanModel {
    private(set) var result: ScanResult?
    private(set) var progress: ScanProgress?
    private(set) var projects: [String] = []
    private var scanTask: Task<Void, Never>?

    var isScanning: Bool { scanTask != nil }

    /// Starts a scan of this Mac plus every registered and discovered project. Stop keeps partial results.
    func startScan() {
        guard scanTask == nil else { return }
        let environment = ClaudeEnvironment.current()
        let fs = LocalFileSystem()
        let registry = ProjectRegistry(file: ProjectRegistry.defaultFile(home: environment.home))
        let projects = ProjectRegistry.deduplicated(
            registry.load(fileSystem: fs).0.map(\.path)
                + ProjectDiscovery(fileSystem: fs).knownProjects(environment: environment),
            fileSystem: fs)
        self.projects = projects

        // GUI apps get a minimal PATH; `locate` also checks the usual install folders.
        let cli = ClaudeCLI.locate(
            environment: ProcessInfo.processInfo.environment, home: environment.home, fileSystem: fs
        ).map { ClaudeCLI(executable: $0) }
        let scanner = Scanner(
            environment: ClaudeEnvironment(
                home: environment.home, configDir: environment.configDir, pluginsDir: environment.pluginsDir,
                managedDir: environment.managedDir, projects: projects),
            target: .mac, fileSystem: fs, cli: cli)

        progress = ScanProgress(step: .settings, itemCount: 0)
        scanTask = Task {
            let result = await Self.run(scanner) { [weak self] update in
                Task { @MainActor in self?.progress = update }
            }
            self.result = result
            self.progress = nil
            self.scanTask = nil
        }
    }

    func stop() {
        scanTask?.cancel()
    }

    nonisolated private static func run(
        _ scanner: Scanner, progress: @escaping @Sendable (ScanProgress) -> Void
    ) async -> ScanResult {
        await scanner.scan(progress: progress)
    }

    func items(in filter: SidebarFilter, matching query: String) -> [Item] {
        let items = result?.items ?? []
        let filtered: [Item] =
            switch filter {
            case .all: items
            case .bucket(let bucket): items.filter { $0.bucket == bucket }
            case .concept(let concept): items.filter { $0.concept == concept }
            }
        guard !query.isEmpty else { return filtered }
        return filtered.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    func count(_ filter: SidebarFilter) -> Int { items(in: filter, matching: "").count }
}

enum SidebarFilter: Hashable {
    case all
    case bucket(Bucket)
    case concept(Concept)
}
