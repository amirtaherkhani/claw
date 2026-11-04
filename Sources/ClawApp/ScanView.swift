import ClawCore
import SwiftUI
import UniformTypeIdentifiers

/// Scan page (PRD F02): target, live progress, and the concept-to-owner flow.
struct ScanView: View {
    let model: AppModel
    @State private var choosingFolder = false
    @State private var folderTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Scan all configuration", subtitle: subtitle) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(targetDescription).font(.callout)
                    HStack(spacing: 6) {
                        if model.isScanning { ProgressView().controlSize(.small) }
                        Text(statusLine).font(.callout).foregroundStyle(Theme.muted)
                    }
                    if let folder = folderTarget, !model.isRegistered(folder),
                        ProjectInspection.inspect(folder, fileSystem: model.fileSystem).isProject
                    {
                        Button("Add this folder to Projects ›") { model.addProjectPath = folder }
                            .buttonStyle(.link)
                    }
                }
                .panel(padding: 12)
                .frame(maxWidth: 380)
            }

            HStack(spacing: 8) {
                Chip(title: "This Mac", selected: folderTarget == nil) { folderTarget = nil }
                ForEach(model.allProjects.prefix(6), id: \.self) { path in
                    Chip(title: URL(fileURLWithPath: path).lastPathComponent, selected: folderTarget == path) {
                        folderTarget = path
                    }
                }
                Chip(title: "Choose folder…", selected: false) { choosingFolder = true }
            }

            FlowView(flow: SourceFlow.concepts(of: model.items)) { node in
                if let bucket = node.bucket { model.destination = .concept(firstConcept(in: bucket)) }
            }
            .panel()
            .overlay(alignment: .topLeading) {
                if model.result != nil {
                    Text("Click an owner group to see what you can edit")
                        .font(.caption).foregroundStyle(Theme.muted).padding(14)
                }
            }

            if let progress = model.progress {
                HStack(spacing: 10) {
                    ProgressView(value: progress.step.fraction)
                    Text("\(Int(progress.step.fraction * 100))%").monospacedDigit().foregroundStyle(Theme.muted)
                }
            }

            HStack {
                if model.isScanning {
                    Button("Stop") { model.stopScan() }
                } else {
                    Button(folderTarget == nil ? "Scan all" : "Scan this folder") {
                        model.startScan(target: folderTarget.map(ScanTarget.folder) ?? .mac)
                    }
                    .buttonStyle(.glassProminent)
                }
                Button("History", systemImage: "clock.arrow.circlepath") { model.destination = .history }
                    .labelStyle(.iconOnly)
            }
            .controlSize(.large)
        }
        .padding(28)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { folderTarget = url.path }
        }
    }

    private var subtitle: String {
        "Reads all seven kinds of configuration and sorts every item into Yours, Read-only or Needs attention. Nothing is changed."
    }

    private var targetDescription: String {
        if let folder = folderTarget {
            return "One folder: \(ItemPresentation.abbreviate(folder, home: model.home))"
        }
        return "This Mac: ~/.claude, managed settings and \(model.allProjects.count) projects"
    }

    private var statusLine: String {
        if let progress = model.progress { return "\(progress.step.label) · \(progress.itemCount) items so far" }
        guard let result = model.result else { return "Not scanned yet" }
        let seconds = result.finishedAt.timeIntervalSince(result.startedAt)
        return "Last scan: \(result.items.count) items in \(String(format: "%.1f", seconds)) s"
            + (result.partial ? " (partial)" : "")
    }

    /// Opens the first concept that has items in the bucket.
    private func firstConcept(in bucket: Bucket) -> Concept {
        Concept.allCases.first { concept in model.items.contains { $0.concept == concept && $0.bucket == bucket } }
            ?? .plugins
    }
}
