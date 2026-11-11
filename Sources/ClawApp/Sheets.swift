import ClawCore
import SwiftUI
import UniformTypeIdentifiers

/// Item detail (PRD F06): who owns it and why, what controls it, and what a change would write.
struct ItemDetailSheet: View {
    let model: AppModel
    let item: Item
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Monogram(text: ItemPresentation.monogram(item.name), bucket: item.bucket, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.title3.weight(.semibold)).lineLimit(1)
                    Text("\(ItemPresentation.conceptSingular(item.concept)) · \(ItemPresentation.scopeTitle(item.scope))")
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                BucketBadge(bucket: item.bucket)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    actions
                    Label(ItemPresentation.note(item), systemImage: "info.circle")
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if !item.description.isEmpty {
                        section("About") { Text(item.description).textSelection(.enabled) }
                    }
                    section("Details") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            ForEach(ItemPresentation.meta(item, home: model.home)) { row in
                                GridRow {
                                    Text(row.key).foregroundStyle(Theme.muted)
                                    Text(row.value).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    section("Controlled by") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.control.key).font(.callout.monospaced()).textSelection(.enabled)
                            Text(ItemPresentation.controlState(item.control.status)).font(.caption)
                                .foregroundStyle(item.control.status == .unknown ? Theme.attention : Theme.muted)
                        }
                    }
                    if !item.problems.isEmpty {
                        section("Problems") {
                            ForEach(Array(item.problems.enumerated()), id: \.offset) { _, problem in
                                Label(
                                    problem.message,
                                    systemImage: problem.severity == .note ? "info.circle" : "exclamationmark.triangle")
                            }
                        }
                    }
                    if let preview {
                        section("On apply") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(preview.target).font(.callout.monospaced()).foregroundStyle(Theme.muted)
                                DiffView(lines: preview.preview)
                            }
                        }
                    }
                    let routes = model.commands.routes(
                        for: item, scope: model.writeScope?.scope, claudeAvailable: model.claudeFound)
                    if !routes.isEmpty {
                        section("How Claw changes it") {
                            ForEach(routes, id: \.0) { operation, route in
                                RouteRow(operation: operation, route: route)
                            }
                        }
                    }
                    Text(ItemPresentation.how(item)).font(.callout).foregroundStyle(Theme.muted)
                }
                .padding(20)
            }
        }
        .frame(width: 600, height: 640)
        .tint(Theme.text)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if item.capabilities.edit {
                Button("Edit Source…") { model.openInEditor(ItemPresentation.file(item)) }
                    .tint(Theme.accent)
            }
            if item.capabilities.toggle {
                Button(toggleLabel) { model.toggle(item) }
            }
            if item.capabilities.remove {
                Button(removeLabel, role: .destructive) { model.toggleRemoval(item) }
                    .tint(Theme.danger)
            }
            Button("Reveal in Finder") { model.reveal(ItemPresentation.file(item)) }
            Spacer()
        }
    }

    private var toggleLabel: String {
        if let pending = model.queue.pending(for: item.id), pending.action != .remove {
            return String(localized: "Undo \(pending.title)")
        }
        return item.enabled ? String(localized: "Disable") : String(localized: "Enable")
    }

    private var removeLabel: String {
        model.queue.isQueuedForRemoval(item)
            ? String(localized: "Keep") : (item.capabilities.removeLabel ?? String(localized: "Remove"))
    }

    /// The queued change, or what toggling would do.
    private var preview: PendingChange? {
        if let pending = model.queue.pending(for: item.id) { return pending }
        guard item.capabilities.toggle else { return nil }
        return ChangeQueue.preview(
            item, action: item.enabled ? .disable : .enable, writeScope: model.writeScope, home: model.home)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}

/// One way an item changes: Claude Code's own command, or Claw's file edit when Claude Code has none.
private struct RouteRow: View {
    let operation: ControlOperation
    let route: ControlRoute

    private var verb: String {
        switch operation {
        case .enable: String(localized: "Turn on")
        case .disable: String(localized: "Turn off")
        case .remove: String(localized: "Remove")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch route {
            case .claude(let command):
                Label("\(verb) with Claude Code's command", systemImage: "terminal")
                Text(command).font(.callout.monospaced()).foregroundStyle(Theme.muted).textSelection(.enabled)
            case .claw(let how, let reason):
                Label("\(verb): \(how)", systemImage: "doc.badge.gearshape")
                Text(reason).font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .font(.callout)
    }
}

/// Review changes (PRD F11, ROADMAP M4.2 and M4.3): the real diff of every queued change, planned off the main actor,
/// with secrets masked, the backup folder and a checklist. Apply runs the reviewed plans, shows each step, then what
/// happened to every change.
struct ReviewSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Risky changes the person ticked; a change that is no longer queued drops out.
    @State private var confirmed: Set<String> = []

    private struct Inputs: Equatable {
        let queue: ChangeQueue
        let scope: WriteScope?
        let project: String?
        let scan: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if model.isApplying {
                        Text("Applying…").font(.title2.weight(.semibold))
                        Text("Close is back when it is done.").foregroundStyle(Theme.muted)
                    } else if let outcome = model.applyOutcome {
                        Text("Apply result").font(.title2.weight(.semibold))
                        Text(
                            outcome.wroteNothing
                                ? "Your files are as they were." : "History keeps every Apply with its backup."
                        )
                        .foregroundStyle(Theme.muted)
                    } else {
                        Text("Review \(ItemPresentation.counted(model.queue.count, "change"))")
                            .font(.title2.weight(.semibold))
                        Text("Nothing is written until you click Apply.").foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isApplying)
            }
            .padding(20)
            Divider()

            if model.isApplying {
                ApplyProgress(step: model.applyStep)
            } else if let outcome = model.applyOutcome {
                ScrollView {
                    ApplyOutcomePanel(outcome: outcome).padding(20)
                }
            } else if model.queue.isEmpty {
                ContentUnavailableView(
                    "No changes queued", systemImage: "checklist",
                    description: Text("Turn items on or off, or remove them, and they appear here for review.")
                )
                .centeredEmptyState()
            } else if let review = model.review {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(review.entries) { entry in
                            ReviewEntryCard(model: model, entry: entry, confirmed: $confirmed)
                        }
                        ReviewChecklist(review: review)
                    }
                    .padding(20)
                }
            } else {
                ProgressView("Planning the changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            footer.padding(16)
        }
        .frame(width: 700, height: 720)
        .tint(Theme.text)
        .interactiveDismissDisabled(model.isApplying)
        .task(
            id: Inputs(
                queue: model.queue, scope: model.writeScope, project: model.activeProject, scan: model.scanGeneration)
        ) {
            await model.refreshReview()
        }
        .onDisappear { model.dismissApplyOutcome() }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if let outcome = model.applyOutcome {
                Spacer()
                switch outcome.kind {
                case .applied:
                    Button("Done") { dismiss() }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                        .keyboardShortcut(.defaultAction)
                case .stale:
                    Button("Back to Review") { model.dismissApplyOutcome() }
                    Button("Scan Again") { model.rescanAfterStale() }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                        .keyboardShortcut(.defaultAction)
                case .rolledBack, .failed, .refused:
                    Button("Back to Review") { model.dismissApplyOutcome() }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Button("Discard All", role: .destructive) { model.queue.clear() }
                    .tint(Theme.danger)
                    .disabled(model.queue.isEmpty || model.isApplying)
                Spacer()
                Button("Cancel") { dismiss() }.disabled(model.isApplying)
                Button("Apply \(ItemPresentation.counted(model.queue.count, "change"))") {
                    Task { await model.apply(confirmed: confirmed) }
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .disabled(
                    model.review?.canApply(confirmed: confirmed) != true || model.isApplying || model.isScanning
                )
                .help(
                    model.review.map { !$0.needsConfirmation.allSatisfy(confirmed.contains) } == true
                        ? "Confirm each change marked with a warning first" : "Apply the reviewed changes")
            }
        }
    }
}

/// Apply at work: the step it reached, as a bar and in words.
private struct ApplyProgress: View {
    let step: ApplyStep?

    var body: some View {
        VStack(spacing: 10) {
            ProgressView(value: step?.fraction ?? 0)
                .frame(width: 320)
            Text(step?.label ?? "Checking the files")
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Applying: \(step?.label ?? "Checking the files")")
    }
}

/// What Apply did: the headline, why it was undone or not written, each change, files left alone, and the backup.
private struct ApplyOutcomePanel: View {
    let outcome: ApplyOutcome

    private var symbol: (name: String, color: Color) {
        switch outcome.kind {
        case .applied: ("checkmark.circle.fill", Theme.added)
        case .rolledBack: ("arrow.uturn.backward.circle.fill", Theme.attention)
        case .failed: ("xmark.octagon.fill", Theme.danger)
        case .stale, .refused: ("exclamationmark.triangle.fill", Theme.attention)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(outcome.headline).font(.title3.weight(.semibold))
            } icon: {
                Image(systemName: symbol.name).foregroundStyle(symbol.color)
            }
            if let detail = outcome.detail {
                Text(detail).font(.callout)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(outcome.changes) { change in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(change.title).font(.headline)
                            Spacer()
                            Text(stateText(change.state)).font(.callout).foregroundStyle(Theme.muted)
                        }
                        if let guidance = change.guidance {
                            Text(guidance).font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            .panel(padding: 14)
            if outcome.kind == .applied {
                AfterApplyPanel(guidance: AfterApplyGuidance.make(outcome))
            }
            if !outcome.kept.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Left alone, because another program changed them:").font(.callout.weight(.semibold))
                    ForEach(outcome.kept, id: \.self) { path in
                        Text(path).font(.callout.monospaced())
                    }
                }
            }
            ForEach(outcome.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(Theme.muted)
            }
            if let id = outcome.backupId {
                Label("Backup \(id) in ~/.claude.bak", systemImage: "archivebox")
                    .font(.callout).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stateText(_ state: ApplyOutcome.Change.State) -> String {
        switch state {
        case .applied: String(localized: "Applied")
        case .undone: String(localized: "Undone")
        case .notWritten: String(localized: "Not written")
        }
    }
}

/// One change: what it is, each file with its diff, moves, CLI steps, the hook stash and notes.
private struct ReviewEntryCard: View {
    let model: AppModel
    let entry: ReviewEntry
    @Binding var confirmed: Set<String>

    private var change: PendingChange? { model.queue.changes.first { $0.id == entry.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ItemPresentation.conceptSingular(entry.concept))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay { Capsule().strokeBorder(Theme.border) }
                Text(entry.title).font(.headline)
                Spacer()
                if let change = model.queue.changes.first(where: { $0.id == entry.id }) {
                    Button("Discard", systemImage: "xmark") { model.queue.discard(change) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.muted)
                        .accessibilityLabel("Discard \(entry.title)")
                }
            }
            if let change, change.action == .remove, change.concept == .plugins {
                Toggle("Keep the plugin's data", isOn: keepData(change))
                    .toggleStyle(.checkbox)
                    .help("Claude Code deletes a plugin's data folder when it leaves its last scope, unless this is on")
            }
            if !entry.risks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entry.risks, id: \.self) { risk in
                        Label(risk.confirmation, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.attention)
                    }
                    Toggle("I understand; make this change", isOn: confirmation)
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Confirm \(entry.title)")
                }
                .font(.callout)
                .padding(10)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.attention.opacity(0.6)) }
            }
            if let error = entry.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                    .font(.callout)
            }
            ForEach(entry.files) { file in
                HStack {
                    Text(file.path).font(.callout.monospaced()).foregroundStyle(Theme.muted)
                    if file.byClaude {
                        Text("written by claude").font(.caption).foregroundStyle(Theme.muted)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay { Capsule().strokeBorder(Theme.border) }
                    }
                }
                DiffView(lines: file.lines)
            }
            ForEach(entry.moves, id: \.self) { path in
                Label("Moves to the backup: \(path)", systemImage: "archivebox")
                    .font(.callout)
            }
            ForEach(entry.commands, id: \.self) { command in
                Label(command, systemImage: "terminal").font(.callout.monospaced())
            }
            if let stash = entry.stash {
                Label(stash, systemImage: "tray.and.arrow.down").font(.callout)
            }
            ForEach(entry.notes, id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .panel(padding: 14)
    }

    private var confirmation: Binding<Bool> {
        Binding(
            get: { confirmed.contains(entry.id) },
            set: { on in
                if on { confirmed.insert(entry.id) } else { confirmed.remove(entry.id) }
            })
    }

    private func keepData(_ change: PendingChange) -> Binding<Bool> {
        Binding(get: { change.keepData }, set: { model.queue.setKeepData(change, $0) })
    }
}

/// Backup, atomic write and the other promises Apply keeps, plus the reload note for plugin changes.
private struct ReviewChecklist: View {
    let review: Review

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(review.checklist, id: \.self) { line in
                Label(line, systemImage: "checkmark.shield")
            }
            if review.needsReloadPlugins {
                Label(
                    "Open sessions need /reload-plugins or a restart to pick up the plugin change.",
                    systemImage: "arrow.clockwise")
            }
        }
        .font(.callout)
        .foregroundStyle(Theme.muted)
    }
}

/// History (PRD F12, ROADMAP M4.4): every Apply with its backup, newest first, and Restore for a finished one.
struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var filter: HistoryFilter = .all

    private var rows: [HistoryRow] { HistoryList.filter(model.history, query: query, filter: filter) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                title: String(localized: "History"),
                subtitle: String(localized: "Every apply is recorded with its backup, so you can restore it."),
                writesTo: "~/.claude.bak/")
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search all change records…", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search change records")
            }
            .panel(padding: 10)
            HStack(spacing: 8) {
                ForEach(HistoryFilter.allCases, id: \.self) { candidate in
                    Chip(title: Self.title(candidate), selected: filter == candidate) { filter = candidate }
                }
            }
            Text(ItemPresentation.counted(rows.count, "record")).foregroundStyle(Theme.muted)
            ForEach(model.historyProblems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.attention)
            }
            if model.history.isEmpty {
                ContentUnavailableView(
                    "No changes applied yet", systemImage: "clock.arrow.circlepath",
                    description: Text("Each apply appears here with its backup and a Restore button.")
                )
                .centeredEmptyState()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(rows) { row in
                            HistoryRowView(row: row) {
                                model.restoring = row
                                model.prepareRestore()
                            }
                        }
                    }
                }
            }
        }
        .padding(28)
        .onAppear { model.loadHistory() }
        .sheet(item: $model.restoring, onDismiss: model.closeRestore, content: { _ in RestoreSheet(model: model) })
    }

    static func title(_ filter: HistoryFilter) -> String {
        switch filter {
        case .all: String(localized: "All")
        case .applied: String(localized: "Applied")
        case .restores: String(localized: "Restores")
        case .undone: String(localized: "Undone")
        }
    }
}

/// One Apply: what it was, when, how it ended, and Restore when its backup is complete.
private struct HistoryRowView: View {
    let row: HistoryRow
    let restore: () -> Void

    private var result: (text: String, symbol: String, color: Color) {
        switch row.result {
        case .applied: (String(localized: "Applied"), "checkmark.circle", Theme.added)
        case .rolledBack: (String(localized: "Rolled back"), "arrow.uturn.backward.circle", Theme.attention)
        case .failed: (String(localized: "Rollback did not finish"), "xmark.octagon", Theme.danger)
        case .inProgress: (String(localized: "Interrupted"), "exclamationmark.circle", Theme.attention)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.isRestore ? "clock.arrow.circlepath" : result.symbol)
                .foregroundStyle(result.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.headline)
                Text(
                    "\(ItemPresentation.counted(row.files.count, "file")) · \(row.date?.formatted(date: .abbreviated, time: .shortened) ?? row.time) · \(result.text)"
                )
                .font(.callout).foregroundStyle(Theme.muted)
                .help(row.files.joined(separator: "\n"))
            }
            Spacer()
            Button("Restore…", systemImage: "arrow.uturn.backward", action: restore)
                .disabled(!row.canRestore)
                .help(
                    row.canRestore
                        ? "Put these files back as they were before this change"
                        : "Nothing to restore: this change did not finish"
                )
                .accessibilityLabel("Restore: \(row.title)")
        }
        .panel(padding: 12)
    }
}

/// What to do in Claude Code now (FR-F17): changes grouped by when they take effect, with the command to copy.
/// Claw never types into a running session.
private struct AfterApplyPanel: View {
    let guidance: AfterApplyGuidance
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(guidance.needsAction ? "In Claude Code" : "In Claude Code: nothing to do")
                .font(.headline)
            ForEach(guidance.groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(group.title, systemImage: symbol(group.effect)).font(.callout.weight(.semibold))
                        Spacer()
                        if let command = group.copy {
                            Button(copied == command ? "Copied" : "Copy \(command)", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                                copied = command
                            }
                            .help("Copy \(command), then paste it into a running Claude Code session")
                        }
                    }
                    Text(group.detail).font(.caption).foregroundStyle(Theme.muted)
                    Text(group.changes.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 14)
    }

    private func symbol(_ effect: PlanEffect) -> String {
        switch effect {
        case .live: "bolt.fill"
        case .reloadPlugins: "arrow.clockwise"
        case .afterClear: "eraser"
        case .newSession: "plus.bubble"
        }
    }
}

/// Restore (FR-F12-3): what the backup puts back, each file changed since then to accept or leave, then the
/// restore through the same pipeline as Apply, with a backup of its own first.
private struct RestoreSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var accepted: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Restore \(model.restoring?.title ?? "")").font(.title2.weight(.semibold))
                    Text("Puts the files back as they were before this change. A new backup is made first.")
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isRestoring)
            }
            .padding(20)
            Divider()

            Group {
                if model.isRestoring {
                    ApplyProgress(step: model.applyStep)
                } else if let outcome = model.restoreOutcome {
                    ScrollView { ApplyOutcomePanel(outcome: outcome).padding(20) }
                } else if let error = model.restoreError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let preview = model.restorePreview {
                    ScrollView { RestorePreviewView(preview: preview, accepted: $accepted).padding(20) }
                } else {
                    ProgressView("Reading the backup…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            HStack {
                Spacer()
                if model.restoreOutcome != nil {
                    Button("Done") { dismiss() }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.disabled(model.isRestoring)
                    Button("Restore") { Task { await model.runRestore() } }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                        .disabled(model.restorePreview?.canRestore != true || model.isRestoring)
                }
            }
            .padding(16)
        }
        .frame(width: 700, height: 640)
        .tint(Theme.text)
        .interactiveDismissDisabled(model.isRestoring)
        .onChange(of: accepted) { _, newValue in model.prepareRestore(accept: newValue) }
    }
}

/// The restore plan: changes made after the backup first, then each file put back with its diff.
private struct RestorePreviewView: View {
    let preview: RestorePreview
    @Binding var accepted: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !preview.conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Changed after the backup", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(Theme.attention)
                    Text("Another change or program wrote these since. Restore over each one only if you mean to.")
                        .font(.callout).foregroundStyle(Theme.muted)
                    ForEach(preview.conflicts) { conflict in
                        Toggle(isOn: binding(conflict.file)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conflict.path).font(.callout.monospaced())
                                Text(conflict.reason).font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Restore over \(conflict.path)")
                    }
                }
                .panel(padding: 14)
            }
            ForEach(preview.files) { file in
                VStack(alignment: .leading, spacing: 6) {
                    Text(file.path).font(.callout.monospaced()).foregroundStyle(Theme.muted)
                    DiffView(lines: file.lines)
                }
            }
            ForEach(preview.movedAside, id: \.self) { path in
                Label("Created by this change; moves aside into the new backup: \(path)", systemImage: "archivebox")
                    .font(.callout)
            }
            if preview.stashCount > 0 {
                Label(
                    "\(ItemPresentation.counted(preview.stashCount, "hook")) taken back out of Claw's stash",
                    systemImage: "tray.and.arrow.up"
                )
                .font(.callout)
            }
            if !preview.alreadyRestored.isEmpty {
                Text("Already as the backup has them: \(preview.alreadyRestored.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            if !preview.canRestore, preview.conflicts.isEmpty {
                Label("Everything is already as the backup has it.", systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func binding(_ file: String) -> Binding<Bool> {
        Binding(
            get: { accepted.contains(file) },
            set: { on in
                if on { accepted.insert(file) } else { accepted.remove(file) }
            })
    }
}

/// Add plugin (PRD F09): pick a source, see what it contains and who will own it, then install (M5).
struct AddPluginSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var source: PluginSourceInspection.Source = .localFolder
    @State private var folder: String?
    @State private var repository = ""
    @State private var marketplace = ""
    @State private var pluginName: String?
    @State private var scope: SettingsScope = .user
    @State private var choosingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add plugin").font(.title2.weight(.semibold))
                    Text("Choose where the plugin comes from. The source decides whether you can edit it.")
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            Picker("Source", selection: $source) {
                Text("Local folder").tag(PluginSourceInspection.Source.localFolder)
                Text("GitHub repo").tag(PluginSourceInspection.Source.github)
                Text("Registered marketplace").tag(PluginSourceInspection.Source.marketplace)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Theme.segment)

            sourceInput

            if let inspection {
                if !inspection.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Plugins in this marketplace").font(.headline)
                        ForEach(inspection.entries) { entry in
                            Button {
                                pluginName = entry.name
                            } label: {
                                HStack {
                                    Image(systemName: pluginName == entry.name ? "largecircle.fill.circle" : "circle")
                                    VStack(alignment: .leading) {
                                        Text(entry.name).fontWeight(.medium)
                                        Text(entry.subtitle).font(.caption).foregroundStyle(Theme.muted)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .panel(padding: 12)
                }
                HStack(alignment: .top, spacing: 10) {
                    BucketBadge(bucket: inspection.outcome.bucket)
                    Text(inspection.outcomeText).font(.callout)
                }
                ForEach(inspection.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.attention)
                }
            }

            HStack {
                Text("Enable in")
                Picker("Enable in", selection: $scope) {
                    Text("User").tag(SettingsScope.user)
                    Text("Project").tag(SettingsScope.project).disabled(model.activeProject == nil)
                    Text("Local").tag(SettingsScope.local).disabled(model.activeProject == nil)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(Theme.segment)
                .frame(width: 240)
                Text("writes \(targetFile)").font(.callout.monospaced()).foregroundStyle(Theme.muted)
            }

            if let inspection {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(inspection.commands(pluginName: pluginName, scope: scope, input: input), id: \.self) {
                        Text($0).font(.callout.monospaced()).textSelection(.enabled)
                    }
                    Text(
                        "Claw runs these with the claude CLI, then checks enabledPlugins afterwards and flags \"installed but not enabled\"."
                    )
                    .font(.caption).foregroundStyle(Theme.muted)
                }
                .panel(padding: 12)
            }

            HStack {
                Spacer()
                Text("Installing arrives in milestone M5.").font(.caption).foregroundStyle(Theme.muted)
                Button("Cancel") { dismiss() }
                Button("Add plugin") {}
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .disabled(true)
            }
        }
        .padding(24)
        .frame(width: 720)
        .tint(Theme.text)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { folder = url.path }
        }
    }

    @ViewBuilder
    private var sourceInput: some View {
        switch source {
        case .localFolder:
            if let folder {
                HStack {
                    Image(systemName: "folder")
                    Text(ItemPresentation.abbreviate(folder, home: model.home)).font(.callout.monospaced())
                    Spacer()
                    Button("Choose…") { choosingFolder = true }
                }
                .panel(padding: 10)
            } else {
                DropZone(
                    title: String(localized: "Drop a folder here"),
                    detail: String(localized: "It needs .claude-plugin/marketplace.json at its root."),
                    browse: { choosingFolder = true },
                    drop: { url in folder = url.path })
            }
        case .github:
            TextField("owner/repo", text: $repository)
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .panel(padding: 10)
        case .marketplace:
            Picker("Marketplace", selection: $marketplace) {
                Text("Choose…").tag("")
                ForEach(markets.keys.sorted(), id: \.self) { Text($0).tag($0) }
            }
        }
    }

    private var markets: [String: MarketplaceRecord] {
        MarketplaceReader(fileSystem: model.fileSystem).readKnown(file: model.environment.knownMarketplacesFile).0
    }

    private var input: String {
        switch source {
        case .localFolder: folder ?? ""
        case .github: repository
        case .marketplace: marketplace
        }
    }

    private var inspection: PluginSourceInspection? {
        switch source {
        case .localFolder: folder.map { PluginSourceInspection.localFolder($0, fileSystem: model.fileSystem) }
        case .github: repository.isEmpty ? nil : PluginSourceInspection.github(repository)
        case .marketplace: marketplace.isEmpty ? nil : PluginSourceInspection.marketplace(marketplace, markets: markets)
        }
    }

    private var targetFile: String {
        WriteScope.resolve(scope, environment: model.environment, activeProject: model.activeProject)
            .map { ItemPresentation.abbreviate($0.file, home: model.home) } ?? "—"
    }
}
