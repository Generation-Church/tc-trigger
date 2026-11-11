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
        .handlesExternalEvents(matching: ["open"])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        model.applyDockSetting()
        _ = Updater.shared // start Sparkle (scheduled checks) at launch
        // Opened by a person → show the window. Started by macOS at login → stay in the
        // background (the Mac runs unattended), unless setup isn't finished.
        let showWindow = !Self.launchedAtLogin || model.settings.campusName.isEmpty
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue == MainWindow.id {
                if showWindow {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    window.close()
                }
            }
        }
    }

    /// True when macOS opened the app as a login item.
    static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Double-clicking TC Trigger while it's already running opens the main window
    /// (the menu-bar icon can be hidden behind the notch on a crowded menu bar).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showMainWindow()
        return true
    }

    @MainActor static func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == MainWindow.id }) {
            window.makeKeyAndOrderFront(nil)
        } else if let url = URL(string: "tctrigger://open") {
            NSWorkspace.shared.open(url)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
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
