import ClefCore
import Foundation
import Observation

/// UI state for the read-only scan. All mutation happens on the main actor; the scan itself runs off it.
@MainActor
@Observable
final class ScanModel {
    private(set) var result: ScanResult?
    private(set) var isScanning = false

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let environment = ClaudeEnvironment.current()
        let fs = LocalFileSystem()
        // GUI apps get a minimal PATH; `locate` also checks the usual install folders.
        let cli = ClaudeCLI.locate(
            environment: ProcessInfo.processInfo.environment,
            home: environment.home, fileSystem: fs
        )
        .map { ClaudeCLI(executable: $0) }
        let scanner = Scanner(environment: environment, target: .mac, fileSystem: fs, cli: cli)
        result = await Self.run(scanner)
    }

    nonisolated private static func run(_ scanner: Scanner) async -> ScanResult {
        await scanner.scan()
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
