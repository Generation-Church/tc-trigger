import AppKit
import Combine
import Sparkle
import TCTriggerKit

/// "Check for Updates…" via Sparkle, against the latest GitHub release's appcast.
///
/// - Updates are verified with an EdDSA signature (public key baked into Info.plist at build
///   time) and must be code-signed by the same certificate as the installed app.
/// - Automatic daily checks are skipped while armed, so an update window can never take focus
///   from Ableton during a service. Manual checks always run.
/// - Updates are never installed without someone clicking Install.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    /// False when this build has no update-signing key (see scripts/setup-updates.sh).
    let isConfigured: Bool
    @Published private(set) var canCheck = false

    private var controller: SPUStandardUpdaterController!
    private var cancellable: AnyCancellable?

    private override init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = !key.trimmingCharacters(in: .whitespaces).isEmpty
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: isConfigured, updaterDelegate: self,
                                                 userDriverDelegate: nil)
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }
    }

    func checkForUpdates() {
        AppModel.shared.log.info(.app, "update.check", "Checking for updates (manual)")
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
            AppModel.shared.log.info(.settings, "settings.changed", "Check for updates automatically: \(!newValue) → \(newValue)",
                                     ["setting": "automaticUpdateChecks", "old": .bool(!newValue), "new": .bool(newValue),
                                      "source": "ui"])
        }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated static let skipDomain = "TCTrigger.UpdateSkippedWhileArmed"

    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground else { return }
        let armed = MainActor.assumeIsolated { AppModel.shared.settings.armed }
        if armed {
            MainActor.assumeIsolated {
                AppModel.shared.log.info(.app, "update.skipped", "Skipped the automatic update check because TC Trigger is armed")
            }
            throw NSError(domain: Self.skipDomain, code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Automatic update checks are skipped while armed."])
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        MainActor.assumeIsolated {
            AppModel.shared.log.info(.app, "update.available", "Update available: TC Trigger \(v)",
                                     ["version": .string(v), "installed": .string(SystemInfo.appVersion)])
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            AppModel.shared.log.info(.app, "update.none", "TC Trigger is up to date (\(SystemInfo.appVersion))")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let v = item.displayVersionString
        MainActor.assumeIsolated {
            AppModel.shared.log.info(.app, "update.installing", "Installing TC Trigger \(v) (from \(SystemInfo.appVersion)); the app will relaunch",
                                     ["version": .string(v), "from": .string(SystemInfo.appVersion),
                                      "armed": .bool(AppModel.shared.settings.armed)])
            AppModel.shared.log.flush()
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Our own "skipped while armed" refusal is already logged as update.skipped.
        if (error as NSError).domain == Self.skipDomain { return }
        let msg = error.localizedDescription
        MainActor.assumeIsolated {
            AppModel.shared.log.warning(.app, "update.failed", "Update check or install stopped: \(msg)", ["error": .string(msg)])
        }
    }
}
