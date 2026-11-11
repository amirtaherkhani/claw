import Foundation
import Testing

@testable import ClawCore

/// M4.3: Apply from the Review sheet. The reviewed plans run through the write pipeline on a real temporary HOME,
/// and the outcome says what happened to each change: applied, applied then rolled back, or not written because a
/// file changed since the scan.
@Suite("Apply outcome")
struct ApplyOutcomeTests {
    final class Home: @unchecked Sendable {
        let path: String
        let env: ClaudeEnvironment
        static let settings = "{\n  \"theme\": \"dark\"\n}\n"

        init() throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            path = url.resolvingSymlinksInPath().path
            env = ClaudeEnvironment(home: path, managedDir: joinPath(path, "managed"), projects: [])
            try FileManager.default.createDirectory(
                atPath: joinPath(env.configDir, "skills/tidy"), withIntermediateDirectories: true)
            try put(env.userSettingsFile, Self.settings)
            try put(joinPath(env.configDir, "skills/tidy/SKILL.md"), "---\nname: tidy\ndescription: Tidy\n---\nB\n")
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }

        func put(_ file: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: file)) }
        func read(_ file: String) throws -> String {
            String(decoding: try Data(contentsOf: URL(fileURLWithPath: file)), as: UTF8.self)
        }
        var backups: String { joinPath(path, ".claude.bak") }
        var user: WriteScope { WriteScope(scope: .user, file: env.userSettingsFile) }

        /// A review of one queued change: turn the skill `tidy` off.
        func review() async throws -> Review {
            let fs = LocalFileSystem()
            let items = await ConfigScanner(environment: env, fileSystem: fs, cli: nil).scan().items
            let skill = try #require(items.first { $0.concept == .skills && $0.name.hasSuffix("tidy") })
            var queue = ChangeQueue()
            queue.toggle(skill, writeScope: user, home: path)
            return Review.make(
                queue: queue, items: items, planner: Planner(environment: env, fileSystem: fs), writeScope: user,
                activeProject: nil, home: path)
        }

        func pipeline(
            progress: (@Sendable (ApplyStep) -> Void)? = nil,
            fault: @escaping @Sendable (ApplyStep) throws -> Void = { _ in }
        ) -> ApplyPipeline {
            ApplyPipeline(
                environment: env, store: BackupStore(root: backups), stash: HookStash(root: joinPath(path, "stash")),
                cli: nil, appVersion: "0.1.0", claudeVersion: nil,
                fault: { step in
                    progress?(step)
                    try fault(step)
                })
        }
    }

    struct Injected: Error, CustomStringConvertible {
        var description: String { "injected fault" }
    }

    final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [ApplyStep] = []
        func add(_ step: ApplyStep) { lock.withLock { list.append(step) } }
        var all: [ApplyStep] { lock.withLock { list } }
    }

    @Test("Apply writes the reviewed change and reports it applied, with the backup and when it takes effect")
    func applied() async throws {
        let home = try Home()
        let review = try await home.review()
        #expect(review.canApply)
        let steps = Steps()
        let outcome = await ApplyOutcome.run(review, pipeline: home.pipeline(progress: steps.add), home: home.path)
        #expect(outcome.kind == .applied)
        #expect(outcome.backupId != nil)
        #expect(outcome.changes.count == 1)
        #expect(outcome.changes.first?.state == .applied)
        #expect(outcome.changes.first?.guidance != nil)
        #expect(try home.read(home.env.userSettingsFile).contains("skillOverrides"))
        #expect(steps.all.contains(.filesWritten))
        #expect(ApplyStep.filesWritten.label.isEmpty == false)
    }

    @Test("A failure after the write is rolled back and shown as applied then rolled back")
    func rolledBack() async throws {
        let home = try Home()
        let review = try await home.review()
        let pipeline = home.pipeline(fault: { if $0 == .filesWritten { throw Injected() } })
        let outcome = await ApplyOutcome.run(review, pipeline: pipeline, home: home.path)
        #expect(outcome.kind == .rolledBack)
        #expect(outcome.headline == "Applied, then rolled back")
        #expect(outcome.detail?.contains("injected fault") == true)
        #expect(outcome.backupId != nil)
        #expect(outcome.changes.allSatisfy { $0.state == .undone })
        #expect(try home.read(home.env.userSettingsFile) == Home.settings, "the old bytes are back")
    }

    @Test("A file changed since the scan: nothing is written and the outcome names the file")
    func stale() async throws {
        let home = try Home()
        let review = try await home.review()
        try home.put(home.env.userSettingsFile, "{\n  \"theme\": \"light\"\n}\n")
        let outcome = await ApplyOutcome.run(review, pipeline: home.pipeline(), home: home.path)
        #expect(outcome.kind == .stale)
        #expect(outcome.staleFile == "~/.claude/settings.json")
        #expect(outcome.backupId == nil)
        #expect(outcome.changes.allSatisfy { $0.state == .notWritten })
        #expect(try home.read(home.env.userSettingsFile).contains("light"))
        #expect(!FileManager.default.fileExists(atPath: home.backups), "no backup was started")
    }

    @Test("A review that cannot be applied writes nothing")
    func refused() async throws {
        let home = try Home()
        let outcome = await ApplyOutcome.run(
            Review.make(
                queue: ChangeQueue(), items: [], planner: Planner(environment: home.env, fileSystem: LocalFileSystem()),
                writeScope: nil, activeProject: nil, home: home.path),
            pipeline: home.pipeline(), home: home.path)
        #expect(outcome.kind == .refused)
        #expect(outcome.backupId == nil)
        #expect(!FileManager.default.fileExists(atPath: home.backups))
    }
}
