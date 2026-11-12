import AppKit
import ClawCore
import SwiftUI

@main
struct ClawApp: App {
    /// 1360 × 820, or `CLAW_WINDOW_SIZE` ("1024x740"): UI tests use it to run as on a small display.
    static var initialSize: CGSize {
        let parts = (ProcessInfo.processInfo.environment["CLAW_WINDOW_SIZE"] ?? "").split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else {
            return CGSize(width: 1360, height: 820)
        }
        return CGSize(width: width, height: height)
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Claw") {
            RootView(model: model)
                // Small enough for any Mac display; pages adapt from here up (see AdaptiveRow).
                .frame(minWidth: 720, minHeight: 520)
                .tint(Theme.accent)
                .preferredColorScheme(.dark)
        }
        .defaultSize(Self.initialSize)
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
