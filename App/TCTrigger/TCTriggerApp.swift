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
            MenuBarIcon(state: model.snapshot.lockState, armed: model.snapshot.armed, fireCount: model.snapshot.fireCount)
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

/// Menu-bar icon: gray = idle, blue = locked, green = armed (bolt), yellow flash on every fire.
struct MenuBarIcon: View {
    let state: LockState
    let armed: Bool
    let fireCount: Int
    @State private var flashing = false

    var body: some View {
        Image(nsImage: Self.image(locked: state == .locked, armed: armed, flash: flashing))
            .onChange(of: fireCount) { _, _ in
                flashing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { flashing = false }
            }
    }

    static func image(locked: Bool, armed: Bool, flash: Bool) -> NSImage {
        let name = armed ? "bolt.circle.fill" : "waveform.circle.fill"
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "TC Trigger")!
        let color: NSColor? = flash ? .systemYellow : armed ? .systemGreen : locked ? .systemBlue : nil
        guard let color else {
            base.isTemplate = true
            return base
        }
        let config = NSImage.SymbolConfiguration(paletteColors: [.white, color])
        let img = base.withSymbolConfiguration(config) ?? base
        img.isTemplate = false
        return img
    }
}
