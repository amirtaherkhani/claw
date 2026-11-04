import ClefCore
import SwiftUI

// Layers: the sidebar, toolbar and inspector are system chrome (the functional layer, glass from the system).
// The table, badges and detail text are the content layer: solid fills only, no glassEffect.
struct ContentView: View {
    let model: ScanModel
    @State private var filter: SidebarFilter? = .all
    @State private var selection: Item.ID?
    @State private var query = ""
    @State private var showInspector = true

    private var visibleItems: [Item] { model.items(in: filter ?? .all, matching: query) }
    private var selectedItem: Item? { model.result?.items.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, selection: $filter)
        } detail: {
            detail
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Filter items")
        .inspector(isPresented: $showInspector) {
            ItemInspector(item: selectedItem)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isScanning {
                    Button("Stop", systemImage: "stop.fill", role: .cancel) { model.stop() }
                        .help("Stop and keep what was found so far")
                } else {
                    Button("Scan", systemImage: "arrow.clockwise") { model.startScan() }
                        .buttonStyle(.glassProminent)
                        .help("Scan this Mac and known projects (read-only)")
                }
            }
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let progress = model.progress, model.result == nil {
            ProgressView(value: progress.step.fraction) {
                Text(progress.step.label)
            } currentValueLabel: {
                Text("\(progress.itemCount) items so far")
            }
            .frame(maxWidth: 360)
            .padding()
        } else if model.result == nil {
            ContentUnavailableView {
                Label("No scan yet", systemImage: "magnifyingglass")
            } description: {
                Text("Clef reads your Claude Code configuration. Scanning never changes a file.")
            } actions: {
                Button("Scan This Mac") { model.startScan() }
                    .disabled(model.isScanning)
            }
        } else if visibleItems.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ItemTable(items: visibleItems, selection: $selection)
        }
    }

    private var title: String {
        switch filter ?? .all {
        case .all: "All items"
        case .bucket(let bucket): bucket.title
        case .concept(let concept): concept.title
        }
    }

    private var subtitle: String {
        if let progress = model.progress { return progress.step.label + "…" }
        guard let result = model.result else { return "Not scanned" }
        let version = result.claudeCodeVersion.map { "Claude Code \($0)" } ?? "claude CLI not found"
        let projects = model.projects.isEmpty ? "" : " · \(model.projects.count) projects"
        return "\(visibleItems.count) items\(projects) · \(version)\(result.partial ? " · partial" : "")"
    }
}

private struct Sidebar: View {
    let model: ScanModel
    @Binding var selection: SidebarFilter?

    var body: some View {
        List(selection: $selection) {
            row(.all, "All items", "square.grid.2x2")
            Section("Ownership") {
                ForEach(Bucket.allCases, id: \.self) { bucket in
                    row(.bucket(bucket), bucket.title, bucket.symbol)
                }
            }
            Section("Concepts") {
                ForEach(Concept.allCases, id: \.self) { concept in
                    row(.concept(concept), concept.title, concept.symbol)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    }

    private func row(_ filter: SidebarFilter, _ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .badge(model.result == nil ? 0 : model.count(filter))
            .tag(filter)
    }
}

private struct ItemTable: View {
    let items: [Item]
    @Binding var selection: Item.ID?

    var body: some View {
        Table(items, selection: $selection) {
            TableColumn("Name") { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.body.weight(.medium))
                    if !item.description.isEmpty {
                        Text(item.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            TableColumn("Concept") { item in Text(item.concept.title) }
                .width(min: 70, ideal: 90)
            TableColumn("Owner") { item in OwnershipBadge(bucket: item.bucket) }
                .width(min: 90, ideal: 120)
            TableColumn("State") { item in
                Text(item.enabled ? "On" : "Off").foregroundStyle(item.enabled ? .primary : .secondary)
            }
            .width(min: 40, ideal: 50)
            TableColumn("Scope") { item in Text(item.scope.rawValue.capitalized).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 70)
        }
    }
}

/// Content-layer badge: solid fill plus text, so meaning never depends on color alone.
struct OwnershipBadge: View {
    let bucket: Bucket

    var body: some View {
        Text(bucket.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(bucket == .yours ? Color.black : Color.white)
            .background(bucket.color, in: Capsule())
            .accessibilityLabel("Ownership: \(bucket.title)")
    }
}

private struct ItemInspector: View {
    let item: Item?

    var body: some View {
        if let item {
            Form {
                Section {
                    LabeledContent("Name", value: item.name)
                    LabeledContent("Concept", value: item.concept.title)
                    LabeledContent("Owner") { OwnershipBadge(bucket: item.bucket) }
                    LabeledContent("State", value: item.enabled ? "On" : "Off")
                    if let source = item.enabledBy { LabeledContent("Decided by", value: source) }
                }
                Section("Why this owner") {
                    LabeledContent("Rule", value: item.classification.rule)
                    ForEach(item.classification.evidence, id: \.self) { Text($0).font(.callout) }
                }
                Section("Controlled by") {
                    Text(item.control.key).font(.callout.monospaced()).textSelection(.enabled)
                    if let reason = item.capabilities.reason { Text(reason).font(.callout).foregroundStyle(.secondary) }
                }
                Section("Location") {
                    Text(item.location).font(.callout.monospaced()).textSelection(.enabled)
                }
                if !item.problems.isEmpty {
                    Section("Problems") {
                        ForEach(Array(item.problems.enumerated()), id: \.offset) { _, problem in
                            Label(
                                problem.message,
                                systemImage: problem.severity == .note ? "info.circle" : "exclamationmark.triangle"
                            )
                            .font(.callout)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "No selection", systemImage: "sidebar.trailing",
                description: Text("Select an item to see who owns it and why."))
        }
    }
}

extension Bucket {
    var title: String {
        switch self {
        case .yours: "Yours"
        case .readonly: "Read-only"
        case .attention: "Needs attention"
        }
    }

    var symbol: String {
        switch self {
        case .yours: "person.crop.circle"
        case .readonly: "lock"
        case .attention: "exclamationmark.triangle"
        }
    }

    /// Prototype colors: yellow = Yours, blue = Read-only, orange = Needs attention.
    var color: Color {
        switch self {
        case .yours: .clefAccent
        case .readonly: .blue
        case .attention: .orange
        }
    }
}

extension Concept {
    var title: String {
        switch self {
        case .plugins: "Plugins"
        case .skills: "Skills"
        case .commands: "Commands"
        case .rules: "Rules"
        case .agents: "Subagents"
        case .mcp: "MCP servers"
        case .hooks: "Hooks"
        }
    }

    var symbol: String {
        switch self {
        case .plugins: "puzzlepiece.extension"
        case .skills: "sparkles"
        case .commands: "command"
        case .rules: "doc.text"
        case .agents: "person.2"
        case .mcp: "server.rack"
        case .hooks: "link"
        }
    }
}
