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

/// Review changes (PRD F11). Nothing is written until Apply; Apply arrives with the write pipeline (M2).
struct ReviewSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review \(ItemPresentation.counted(model.queue.count, "change"))")
                        .font(.title2.weight(.semibold))
                    Text("Nothing is written until you click Apply.").foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()

            if model.queue.isEmpty {
                ContentUnavailableView(
                    "No changes queued", systemImage: "checklist",
                    description: Text("Turn items on or off, or remove them, and they appear here for review."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.queue.changes) { change in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(ItemPresentation.conceptSingular(change.concept))
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .overlay { Capsule().strokeBorder(Theme.border) }
                                    Text(change.title).font(.headline)
                                    Spacer()
                                    Button("Discard", systemImage: "xmark") { model.queue.discard(change) }
                                        .labelStyle(.iconOnly)
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Theme.muted)
                                        .accessibilityLabel("Discard \(change.title)")
                                }
                                Text(change.target).font(.callout.monospaced()).foregroundStyle(Theme.muted)
                                DiffView(lines: change.preview)
                                ForEach(change.notes, id: \.self) { note in
                                    Text(note).font(.caption).foregroundStyle(Theme.muted)
                                }
                            }
                            .panel(padding: 14)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Label("A backup is created first in ~/.claude.bak/‹timestamp›/", systemImage: "checkmark.shield")
                            Label(
                                "Files are written atomically; keys Claw does not manage are kept.",
                                systemImage: "lock.doc")
                        }
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                    }
                    .padding(20)
                }
            }

            Divider()
            HStack {
                Button("Discard All", role: .destructive) { model.queue.clear() }
                    .tint(Theme.danger)
                    .disabled(model.queue.isEmpty)
                Spacer()
                Text("Applying arrives with the safe write pipeline (M2).")
                    .font(.caption).foregroundStyle(Theme.muted)
                Button("Cancel") { dismiss() }
                Button("Apply \(ItemPresentation.counted(model.queue.count, "change"))") {}
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .disabled(true)
            }
            .padding(16)
        }
        .frame(width: 680, height: 640)
        .tint(Theme.text)
    }
}

/// History (PRD F12): every apply with Restore. Empty until the write pipeline (M2) records changes.
struct HistoryView: View {
    let model: AppModel
    @State private var query = ""
    @State private var concept: Concept?

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
                Chip(title: String(localized: "All"), selected: concept == nil) { concept = nil }
                ForEach(Concept.allCases, id: \.self) { candidate in
                    Chip(title: ItemPresentation.conceptTitle(candidate), selected: concept == candidate) {
                        concept = candidate
                    }
                }
            }
            Text("0 records").foregroundStyle(Theme.muted)
            ContentUnavailableView(
                "No changes applied yet", systemImage: "clock.arrow.circlepath",
                description: Text(
                    "Each apply will appear here with a Restore button. Applying arrives with the safe write pipeline (M2)."
                ))
            Spacer()
        }
        .padding(28)
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
