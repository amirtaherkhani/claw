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
