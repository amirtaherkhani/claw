import ClawCore
import SwiftUI

// Layers: the sidebar, toolbar and sheets are system chrome (functional layer, glass from the system).
// Pages, panels, tables and badges are the content layer: solid fills only, no glassEffect.
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            RailView(model: model)
        } detail: {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
        }
        .toolbar { StatusToolbar(model: model) }
        .sheet(item: $model.detailItem) { item in ItemDetailSheet(model: model, item: item) }
        .sheet(isPresented: $model.showReview) { ReviewSheet(model: model) }
        .sheet(isPresented: $model.showAddPlugin) { AddPluginSheet(model: model) }
        .sheet(item: folderChoice) { choice in AddProjectSheet(model: model, path: choice.path) }
        .overlay(alignment: .bottom) {
            if let toast = model.toast { ToastView(text: toast) }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
    }

    private var folderChoice: Binding<FolderChoice?> {
        Binding(
            get: { model.addProjectPath.map(FolderChoice.init(path:)) },
            set: { model.addProjectPath = $0?.path })
    }

    @ViewBuilder
    private var page: some View {
        switch model.destination ?? .overview {
        case .overview: OverviewView(model: model)
        case .scan: ScanView(model: model)
        case .projects: ProjectsView(model: model)
        case .history: HistoryView(model: model)
        case .concept(let concept): ConceptView(model: model, concept: concept).id(concept)
        }
    }

    private var title: String {
        switch model.destination ?? .overview {
        case .overview: "Overview"
        case .scan: "Scan"
        case .projects: "Projects"
        case .history: "History"
        case .concept(let concept): ItemPresentation.conceptTitle(concept)
        }
    }

    /// Status pill text: "X of Y items enabled · N pending".
    private var subtitle: String {
        if let progress = model.progress { return progress.step.label + "…" }
        guard model.result != nil else { return "Not scanned yet" }
        let stats = model.stats
        let pending = model.queue.isEmpty ? "" : " · \(model.queue.count) pending"
        return "\(stats.enabled) of \(stats.total) items enabled\(pending)"
    }
}

/// Wraps a folder path so it can drive `.sheet(item:)`.
struct FolderChoice: Identifiable {
    let path: String
    var id: String { path }
}

/// One rail button. The same table drives the rail and the Go menu, so keyboard users reach every page.
struct RailEntry: Identifiable {
    let title: String
    let shortTitle: String
    let symbol: String
    let destination: AppModel.Destination
    var id: AppModel.Destination { destination }

    static let all: [RailEntry] =
        [
            RailEntry(
                title: "Overview", shortTitle: "Overview", symbol: "circle.hexagongrid", destination: .overview),
            RailEntry(title: "Scan", shortTitle: "Scan", symbol: "dot.radiowaves.left.and.right", destination: .scan),
            RailEntry(title: "Projects", shortTitle: "Projects", symbol: "folder", destination: .projects),
        ]
        + Concept.allCases.map { concept in
            let title = ItemPresentation.conceptTitle(concept)
            return RailEntry(
                title: title, shortTitle: concept == .mcp ? "MCP" : title, symbol: Theme.symbol(concept),
                destination: .concept(concept))
        }
        + [
            RailEntry(
                title: "History", shortTitle: "History", symbol: "clock.arrow.circlepath", destination: .history)
        ]
}

/// Icon rail from the prototype. It stays inside the split view's sidebar column, so the glass is system chrome;
/// a ScrollView keeps all eleven buttons reachable at the window's minimum height.
struct RailView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(RailEntry.all) { entry in
                    RailButton(
                        entry: entry, selected: (model.destination ?? .overview) == entry.destination,
                        count: count(entry.destination)
                    ) {
                        model.destination = entry.destination
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(Theme.railWidth)
    }

    /// Counts stay out of the rail, as on the board; they are in the tooltip and read by VoiceOver.
    private func count(_ destination: AppModel.Destination) -> Int? {
        switch destination {
        case .projects: model.allProjects.count
        case .concept(let concept): model.result == nil ? nil : model.count(concept)
        default: nil
        }
    }
}

private struct RailButton: View {
    let entry: RailEntry
    let selected: Bool
    let count: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.muted)
                    .frame(width: 46, height: 34)
                    .background(
                        selected ? Theme.railSelected : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(entry.shortTitle)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(selected ? Theme.accent : Theme.railLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: Theme.railWidth, height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(count.map { "\(entry.title): \($0)" } ?? entry.title)
        .accessibilityLabel(entry.title)
        .accessibilityValue(count.map(String.init) ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Status bar from the prototype: write scope, active project, and one primary action.
struct StatusToolbar: ToolbarContent {
    @Bindable var model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Write scope", selection: scopeBinding) {
                Text("User").tag(SettingsScope.user)
                Text("Project").tag(SettingsScope.project)
                Text("Local").tag(SettingsScope.local)
            }
            .pickerStyle(.segmented)
            .help("Where enable and disable changes are written: \(model.writeScopeLabel)")
        }
        ToolbarItem {
            Menu {
                ForEach(model.allProjects, id: \.self) { path in
                    Button {
                        model.setActiveProject(path)
                    } label: {
                        if path == model.activeProject {
                            Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "checkmark")
                        } else {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                        }
                    }
                }
                if !model.allProjects.isEmpty { Divider() }
                Button("Manage Projects…") { model.destination = .projects }
            } label: {
                Label(
                    model.activeProject.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No project",
                    systemImage: "folder"
                )
                .labelStyle(.titleAndIcon)
            }
            .help("Active project. Project and Local scope write into this folder.")
        }
        ToolbarItem(placement: .primaryAction) {
            if model.isScanning {
                Button("Stop", systemImage: "stop.fill") { model.stopScan() }
                    .help("Stop and keep what was found so far")
            } else if !model.queue.isEmpty {
                Button("Review \(model.queue.count)", systemImage: "checklist") { model.showReview = true }
                    .buttonStyle(.glassProminent)
                    .help("Review queued changes before anything is written")
            } else {
                Button("Scan", systemImage: "arrow.clockwise") { model.startScan() }
                    .buttonStyle(.glassProminent)
                    .help("Scan this Mac and known projects (read-only)")
            }
        }
    }

    /// Project and Local need an active project; otherwise the picker stays on User.
    private var scopeBinding: Binding<SettingsScope> {
        Binding(
            get: { model.scope },
            set: { newValue in
                if newValue != .user && model.activeProject == nil {
                    model.show("Choose an active project first")
                } else {
                    model.scope = newValue
                }
            })
    }
}
