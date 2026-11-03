import AppKit
import ClefCore
import SwiftUI

@main
struct ClefApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ScanModel()

    var body: some Scene {
        WindowGroup("Clef") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .tint(.clefAccent)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan This Mac") { Task { await model.scan() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isScanning)
            }
        }
    }
}

/// `swift run ClefApp` starts a bare executable; make it a regular foreground app with a Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }
}

extension Color {
    /// Brand accent from the prototype (`--acc: #D4F53C`). Used as the app tint only, never as a glass tint.
    static let clefAccent = Color(red: 0xD4 / 255, green: 0xF5 / 255, blue: 0x3C / 255)
}
