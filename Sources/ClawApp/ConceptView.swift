import ClawCore
import SwiftUI

/// One concept: first the Sources flow (PRD F04), then the list for the chosen owner group (PRD F05).
struct ConceptView: View {
    let model: AppModel
    let concept: Concept
    @State private var bucket: Bucket?

    var body: some View {
        if let bucket {
            ItemListView(model: model, concept: concept, bucket: bucket) { self.bucket = $0 }
        } else {
            sources
        }
    }

    private var sources: some View {
        let items = model.items(concept: concept, bucket: nil)
        return VStack(alignment: .leading, spacing: 18) {
            PageHeader(
                title: ItemPresentation.conceptTitle(concept), subtitle: ItemPresentation.conceptSummary(concept),
                writesTo: model.writeScopeLabel, note: model.activeProject == nil ? nil : model.scopeTarget.note)
            if concept == .mcp { MCPScopeNote(lines: model.mcpExplanation) }
            if items.isEmpty {
                // The actions sit inside the empty state: a row pinned to the page bottom can end up under the Dock
                // on a small display, where clicks on it never reach the app.
                ContentUnavailableView {
                    Label(model.result == nil ? "Not scanned yet" : "None found", systemImage: Theme.symbol(concept))
                } description: {
                    Text(
                        model.result == nil
                            ? "Run a scan to see your \(ItemPresentation.conceptTitle(concept).lowercased())."
                            : "No \(ItemPresentation.conceptTitle(concept).lowercased()) on this Mac or in your projects.")
                } actions: {
                    actions
                }
                .centeredEmptyState()
            } else {
                FlowView(flow: SourceFlow.sources(of: items)) { node in bucket = node.bucket }
                    .panel()
                    .overlay(alignment: .topLeading) {
                        Text("Click to see what you can edit").font(.caption).foregroundStyle(Theme.muted).padding(14)
                    }
                actions
            }
        }
        .padding(28)
    }

    private var actions: some View {
        HStack {
            Button("Scan all") { model.startScan() }.disabled(model.isScanning)
            if concept == .plugins {
                Button("Add plugin…") { model.showAddPlugin = true }
            }
            Button("History", systemImage: "clock.arrow.circlepath") { model.destination = .history }
                .labelStyle(.iconOnly)
        }
        .controlSize(.large)
        .tint(Theme.text)
    }
}

/// Owner groups on the left, the item table on the right, bulk actions on top.
struct ItemListView: View {
    let model: AppModel
    let concept: Concept
    let bucket: Bucket
    let select: (Bucket?) -> Void
    @State private var selection = Set<Item.ID>()
    @State private var kind: String?
    @State private var query = ""

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            bucketColumn.frame(width: 230)
            VStack(alignment: .leading, spacing: 10) {
                header
                Text(ItemPresentation.bucketSubtitle(bucket)).font(.callout).foregroundStyle(Theme.muted)
                chips
                table
                footer
            }
        }
        .padding(20)
        .searchable(text: $query, prompt: "Filter \(ItemPresentation.conceptTitle(concept).lowercased())")
        .onChange(of: bucket) { _, _ in selection.removeAll() }
    }

    private var rows: [Item] {
        model.items(concept: concept, bucket: bucket).filter { item in
            (kind == nil || ItemPresentation.kind(item) == kind)
                && (query.isEmpty || item.name.localizedCaseInsensitiveContains(query)
                    || item.description.localizedCaseInsensitiveContains(query))
        }
    }

    private var selectedItems: [Item] { rows.filter { selection.contains($0.id) } }

    private var bucketColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                select(nil)
            } label: {
                Label("Sources", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .padding(.bottom, 4)

            ForEach(Bucket.allCases, id: \.self) { candidate in
                let count = model.items(concept: concept, bucket: candidate).count
                Button {
                    select(candidate)
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(Theme.color(candidate)).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ItemPresentation.bucketTitle(candidate)).font(.callout.weight(.semibold))
                            Text("\(count) · \(ItemPresentation.bucketSubtitle(candidate))")
                                .font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
                    }
                    .padding(10)
                    .background(
                        candidate == bucket ? Theme.panelRaised : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(ItemPresentation.bucketTitle(candidate)), \(ItemPresentation.counted(count, "item"))"
                )
                .accessibilityAddTraits(candidate == bucket ? .isSelected : [])

                if candidate == bucket {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Backup first", systemImage: "checkmark.shield").font(.caption.weight(.semibold))
                            Spacer()
                            Circle().fill(Theme.accent).frame(width: 8, height: 8)
                                .accessibilityLabel("Always on")
                        }
                        Text("Every change is backed up first. Files are moved to the backup folder, never hard-deleted.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    .panel(padding: 10)
                }
            }
            Spacer()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.color(bucket)).frame(width: 10, height: 10)
            Text(ItemPresentation.bucketTitle(bucket)).font(.title2.weight(.semibold))
            Text("\(rows.count)").foregroundStyle(Theme.muted)
            Spacer()
            if selectedItems.isEmpty {
                Text("Select items").foregroundStyle(Theme.muted)
            } else {
                let anyOn = selectedItems.contains { model.queue.effectiveEnabled($0) }
                Button("Remove \(selectedItems.count)", role: .destructive) { model.remove(selectedItems) }
                    .tint(Theme.danger)
                Button(anyOn ? "Disable \(selectedItems.count)" : "Enable \(selectedItems.count)") {
                    model.toggle(selectedItems, enable: !anyOn)
                }
                .tint(Theme.text)
            }
        }
    }

    private var chips: some View {
        let kinds = Array(Set(model.items(concept: concept, bucket: bucket).map(ItemPresentation.kind))).sorted()
        return HStack(spacing: 8) {
            Chip(title: String(localized: "All"), selected: kind == nil) { kind = nil }
            if kinds.count > 1 {
                ForEach(kinds, id: \.self) { candidate in
                    Chip(title: candidate, selected: kind == candidate) { kind = candidate }
                }
            }
            Spacer()
            Text("Scope: \(model.scope.rawValue.capitalized)").font(.callout).foregroundStyle(Theme.muted)
        }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { (item: Item) in
                HStack(spacing: 10) {
                    Monogram(text: ItemPresentation.monogram(item.name), bucket: item.bucket)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).fontWeight(.medium)
                            .strikethrough(model.queue.isQueuedForRemoval(item))
                        if !item.description.isEmpty {
                            Text(item.description).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                }
                .help(item.location)
            }
            .width(min: 200, ideal: 280)
            TableColumn("Modified") { (item: Item) in
                if let date = model.modifiedDate(item) {
                    Text(date, format: .dateTime.day().month(.abbreviated).year()).foregroundStyle(Theme.muted)
                } else {
                    Text("—").foregroundStyle(Theme.muted)
                }
            }
            .width(min: 110, ideal: 130)
            TableColumn("Scope") { (item: Item) in
                Text(ItemPresentation.scopeTitle(item.scope)).foregroundStyle(Theme.muted)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Kind") { (item: Item) in
                Text(ItemPresentation.kind(item)).foregroundStyle(Theme.muted)
            }
            .width(min: 60, ideal: 90)
            TableColumn("On") { (item: Item) in
                Toggle(
                    "Enabled",
                    isOn: Binding(get: { model.queue.effectiveEnabled(item) }, set: { _ in model.toggle(item) })
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!item.capabilities.toggle)
                .help(
                    item.capabilities.toggle ? String(localized: "Queue a change for review") : (item.capabilities.reason ?? "")
                )
                .accessibilityLabel("Enable \(item.name)")
            }
            .width(48)
            TableColumn("") { (item: Item) in
                Button {
                    model.detailItem = item
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted)
                .accessibilityLabel("Details for \(item.name)")
            }
            .width(24)
        }
        .contextMenu(forSelectionType: Item.ID.self) { ids in
            if let id = ids.first, let item = rows.first(where: { $0.id == id }) {
                Button("Details…") { model.detailItem = item }
                Button("Reveal in Finder") { model.reveal(ItemPresentation.file(item)) }
                if item.capabilities.edit {
                    Button("Edit Source…") { model.openInEditor(ItemPresentation.file(item)) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first, let item = rows.first(where: { $0.id == id }) { model.detailItem = item }
        }
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border) }
    }

    private var footer: some View {
        HStack {
            Toggle(
                "Select all",
                isOn: Binding(
                    get: { !rows.isEmpty && selection.count == rows.count },
                    set: { all in selection = all ? Set(rows.map(\.id)) : [] })
            )
            .toggleStyle(.checkbox)
            Spacer()
            Text(
                selectedItems.isEmpty
                    ? ItemPresentation.counted(rows.count, "item")
                    : String(localized: "\(selectedItems.count) of \(rows.count) selected")
            )
            .foregroundStyle(Theme.muted)
        }
        .font(.callout)
    }
}

/// One line on the MCP page: MCP servers have scopes of their own (FR-F13-3). The full mapping opens in a popover,
/// so the page keeps its height.
private struct MCPScopeNote: View {
    let lines: [String]
    @State private var open = false

    var body: some View {
        HStack(spacing: 6) {
            Text("MCP servers have their own scopes, separate from the settings scopes.")
                .font(.callout).foregroundStyle(Theme.muted).lineLimit(1)
            Button("How MCP scopes work", systemImage: "info.circle") { open.toggle() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("How MCP scopes work")
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(lines, id: \.self) { line in
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.callout)
                    .padding(16)
                    .frame(width: 420)
                }
        }
    }
}
