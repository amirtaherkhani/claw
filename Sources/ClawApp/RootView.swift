import ClawCore
import SwiftUI

// Layers: the sidebar, toolbar and sheets are system chrome (functional layer, glass from the system).
// Pages, panels, tables and badges are the content layer: solid fills only, no glassEffect.
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                page
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

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.destination) {
            Section {
                Label("Overview", systemImage: "circle.hexagongrid").tag(AppModel.Destination.overview)
                Label("Scan", systemImage: "dot.radiowaves.left.and.right").tag(AppModel.Destination.scan)
                Label("Projects", systemImage: "folder")
                    .badge(model.allProjects.count)
                    .tag(AppModel.Destination.projects)
            }
            Section("Configuration") {
                ForEach(Concept.allCases, id: \.self) { concept in
                    Label(ItemPresentation.conceptTitle(concept), systemImage: Theme.symbol(concept))
                        .badge(model.result == nil ? 0 : model.count(concept))
                        .tag(AppModel.Destination.concept(concept))
                }
            }
            Section {
                Label("History", systemImage: "clock.arrow.circlepath").tag(AppModel.Destination.history)
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210)
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
                    systemImage: "folder")
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
