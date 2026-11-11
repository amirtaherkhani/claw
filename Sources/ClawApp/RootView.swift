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
            // The toolbar floats over the canvas on every page, scrolled or not.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .toolbar { StatusToolbar(model: model) }
        .sheet(item: $model.detailItem) { item in ItemDetailSheet(model: model, item: item) }
        .sheet(isPresented: $model.showReview) { ReviewSheet(model: model) }
        .sheet(isPresented: $model.showAddPlugin) { AddPluginSheet(model: model) }
        .sheet(isPresented: choosingProject) { ProjectPickerSheet(model: model) }
        .sheet(item: folderChoice) { choice in AddProjectSheet(model: model, path: choice.path) }
        .alert(recoveryTitle, isPresented: $model.recoveryShown, presenting: model.interrupted.first) { change in
            if change.step == .finish {
                Button("OK") { model.recover(change, .ok) }
            } else {
                Button("Cancel", role: .cancel) { model.recover(change, .cancel) }
                if change.canContinue {
                    Button("Continue") { model.recover(change, .continue) }
                }
            }
        } message: { change in
            Text(recoveryMessage(change))
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast { ToastView(text: toast) }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
    }

    private var recoveryTitle: String {
        model.interrupted.first?.step == .finish
            ? String(localized: "Claw stopped after a change")
            : String(localized: "Claw stopped during a change")
    }

    private func recoveryMessage(_ change: InterruptedChange) -> String {
        var text: String
        switch change.step {
        case .backup: text = String(localized: "The last change didn't finish. Nothing was changed yet.")
        case .write: text = String(localized: "The last change didn't finish. Some files may already be changed.")
        case .verify: text = String(localized: "The last change wasn't checked.")
        case .finish: text = String(localized: "The last change was done.")
        }
        if change.step != .finish {
            text += " " + String(localized: "Cancel puts the files back as they were.")
            if change.canContinue {
                text += " " + String(localized: "Continue finishes the change.")
            } else if !change.changedElsewhere.isEmpty {
                text += " " + String(localized: "Continue isn't possible: another program changed the files since.")
            } else {
                text += " " + String(localized: "Continue isn't possible for this older backup.")
            }
        }
        return text
    }

    /// Open while a Project or Local switch waits for a project.
    private var choosingProject: Binding<Bool> {
        Binding(
            get: { model.choosingProjectFor != nil },
            set: { if !$0 { model.choosingProjectFor = nil } })
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
        case .overview: String(localized: "Overview")
        case .scan: String(localized: "Scan")
        case .projects: String(localized: "Projects")
        case .history: String(localized: "History")
        case .concept(let concept): ItemPresentation.conceptTitle(concept)
        }
    }

    /// Status pill text: "X of Y items enabled · N pending".
    private var subtitle: String {
        if let progress = model.progress { return progress.step.label + "…" }
        guard model.result != nil else { return String(localized: "Not scanned yet") }
        let stats = model.stats
        let enabled = String(localized: "\(stats.enabled) of \(stats.total) items enabled")
        return model.queue.isEmpty ? enabled : String(localized: "\(enabled) · \(model.queue.count) pending")
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
                title: String(localized: "Overview"), shortTitle: String(localized: "Overview"), symbol: "circle.hexagongrid",
                destination: .overview),
            RailEntry(
                title: String(localized: "Scan"), shortTitle: String(localized: "Scan"), symbol: "dot.radiowaves.left.and.right",
                destination: .scan),
            RailEntry(
                title: String(localized: "Projects"), shortTitle: String(localized: "Projects"), symbol: "folder",
                destination: .projects),
        ]
        + Concept.allCases.map { concept in
            let title = ItemPresentation.conceptTitle(concept)
            return RailEntry(
                title: title, shortTitle: concept == .mcp ? "MCP" : title, symbol: Theme.symbol(concept),
                destination: .concept(concept))
        }
        + [
            RailEntry(
                title: String(localized: "History"), shortTitle: String(localized: "History"), symbol: "clock.arrow.circlepath",
                destination: .history)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pages")
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
        .accessibilityIdentifier("rail.\(entry.title)")
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
            ScopeDial(selection: model.scope) { model.requestScope($0) }
                .help("Where enable and disable changes are written: \(model.writeScopeLabel)")
        }
        .sharedBackgroundVisibility(.hidden)
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
                    model.activeProject.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "No project"),
                    systemImage: "folder"
                )
                .labelStyle(.titleAndIcon)
            }
            .help("Active project. Project and Local scope write into this folder.")
            .accessibilityLabel("Active project")
            .accessibilityValue(
                model.activeProject.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "No project"))
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
}
