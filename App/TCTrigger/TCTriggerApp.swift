import AppKit
import SwiftUI
import TCTriggerKit

@main
struct TCTriggerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(model)
        } label: {
            MenuBarIcon(state: model.snapshot.lockState)
        }
        .menuBarExtraStyle(.window)

        Window("TC Trigger", id: MainWindow.id) {
            MainWindow()
                .environmentObject(model)
        }
        .defaultSize(width: 640, height: 520)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Runs unattended: only show the window at launch until the campus name is set.
        let needsSetup = AppModel.shared.settings.campusName.isEmpty
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue == MainWindow.id {
                if needsSetup {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    window.close()
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Menu-bar icon: gray when idle, blue when locked to LTC.
struct MenuBarIcon: View {
    let state: LockState

    var body: some View {
        Image(nsImage: Self.image(for: state))
    }

    static func image(for state: LockState) -> NSImage {
        let base = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "TC Trigger")!
        switch state {
        case .locked:
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, .systemBlue])
            let img = base.withSymbolConfiguration(config) ?? base
            img.isTemplate = false
            return img
        case .acquiring, .noSignal:
            base.isTemplate = true
            return base
        }
    }
}
