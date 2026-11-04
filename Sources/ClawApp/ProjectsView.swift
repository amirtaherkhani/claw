import ClawCore
import SwiftUI
import UniformTypeIdentifiers

/// Projects page (PRD F03): registered and discovered folders, and a drop zone to add more.
struct ProjectsView: View {
    let model: AppModel
    @State private var choosingFolder = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Manage project folders", subtitle: subtitle) {
                    Text("Writes only inside folders you add")
                        .font(.callout).foregroundStyle(Theme.muted)
                        .panel(padding: 12)
                }

                if !model.allProjects.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(model.allProjects, id: \.self) { path in
                            ProjectRow(model: model, path: path)
                            if path != model.allProjects.last { Divider().overlay { Theme.border } }
                        }
                    }
                    .panel(padding: 4)
                }

                DropZone(
                    title: "Drop a project folder here",
                    detail:
                        "A project folder is any folder with .claude/, .mcp.json or CLAUDE.md. Claw only reads it until you change something.",
                    browse: { choosingFolder = true },
                    drop: { url in model.addProjectPath = url.path })
            }
            .padding(28)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.addProjectPath = url.path }
        }
    }

    private var subtitle: String {
        let registered = model.registered.count
        let found = model.discovered.count
        return "\(registered) added by you, \(found) found in ~/.claude.json. Claw reads every one on each scan."
    }
}

private struct ProjectRow: View {
    let model: AppModel
    let path: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.headline)
                    if model.activeProject == path {
                        Text("Active").font(.caption.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .foregroundStyle(Color.black)
                            .background(Theme.accent, in: Capsule())
                    }
                }
                Text(ItemPresentation.abbreviate(path, home: model.home))
                    .font(.callout.monospaced()).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(stat).font(.callout).foregroundStyle(Theme.muted)
            if model.activeProject != path {
                Button("Make active") { model.setActiveProject(path) }
            }
            Button("Open") { model.reveal(path) }
            Button("Scan") {
                model.startScan(target: .folder(path))
                model.destination = .scan
            }
            if model.isRegistered(path) {
                Button("Stop managing") { model.removeProject(path) }
                    .accessibilityLabel("Stop managing \(URL(fileURLWithPath: path).lastPathComponent)")
            } else {
                Button("Add") { model.addProjectPath = path }
            }
        }
        .padding(12)
    }

    private var stat: String {
        let items = model.items.filter { $0.projectPath == path }
        let source = model.isRegistered(path) ? "Added by you" : "Found in ~/.claude.json"
        return model.result == nil ? source : "\(items.count) items · \(source)"
    }
}

/// Add project sheet: shows what the folder holds before anything is added.
struct AddProjectSheet: View {
    let model: AppModel
    @State var path: String
    @State private var choosingFolder = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let inspection = ProjectInspection.inspect(path, fileSystem: model.fileSystem)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add project folder").font(.title2.weight(.semibold))
                Text("Claw reads the folder first. Nothing is added until you confirm.").foregroundStyle(Theme.muted)
            }
            HStack {
                Image(systemName: "folder")
                Text(ItemPresentation.abbreviate(path, home: model.home)).font(.callout.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { choosingFolder = true }
            }
            .panel(padding: 10)

            HStack {
                Text("Found in this folder").font(.headline)
                Spacer()
                Text("\(inspection.foundCount)").foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(inspection.rows) { row in
                    HStack {
                        Image(systemName: row.found ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(row.found ? Theme.accent : Theme.muted)
                        Text(row.path).font(.callout.monospaced())
                        Spacer()
                        Text(row.label).font(.callout).foregroundStyle(Theme.muted)
                    }
                }
            }
            .panel(padding: 12)

            Label(
                "Items found here are Yours: they live in a folder you own, so each one gets an Edit button.",
                systemImage: "person.crop.circle"
            )
            .foregroundStyle(Theme.yours)
            Text(
                "After a backup, Claw writes only to .claude/settings.json, .claude/settings.local.json and .mcp.json in this folder. Changes to .claude/settings.json reach everyone who shares the repository."
            )
            .font(.callout).foregroundStyle(Theme.muted)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                if model.isRegistered(path) {
                    Text("Already managed").foregroundStyle(Theme.muted)
                } else {
                    Button("Add folder") {
                        model.addProject(path)
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!inspection.isProject)
                    .help(inspection.isProject ? "Add this folder" : "No .claude/, .mcp.json or CLAUDE.md found")
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { path = url.path }
        }
    }
}
