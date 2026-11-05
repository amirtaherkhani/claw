import AppKit
import ClawCore
import SwiftUI

@main
struct ClawApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Claw") {
            RootView(model: model)
                .frame(minWidth: 1100, minHeight: 680)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1360, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan This Mac") { model.startScan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isScanning)
                Button("Stop Scan") { model.stopScan() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isScanning)
                Divider()
                Button("Review Changes…") { model.showReview = true }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.queue.isEmpty)
            }
            CommandMenu("Go") {
                ForEach(Array(RailEntry.all.enumerated()), id: \.element.id) { index, entry in
                    Button(entry.title) { model.destination = entry.destination }
                        .keyboardShortcut(
                            index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command) : nil)
                }
            }
        }
    }
}

/// `swift run ClawApp` starts a bare executable; make it a regular foreground app with a Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }
}
