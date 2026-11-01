import Foundation
import IOKit.pwr_mgt
import ServiceManagement

/// Keeps the Mac and the app responsive while TC Trigger runs unattended.
public final class Reliability {
    private let log: EventLog
    private var activity: NSObjectProtocol?
    private var sleepAssertion: IOPMAssertionID = 0
    private var holdingSleepAssertion = false

    public init(log: EventLog) {
        self.log = log
    }

    /// Opt out of App Nap and timer coalescing for the whole run. (Idle sleep is still allowed;
    /// it is blocked separately, only while armed.)
    public func disableAppNap() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "TC Trigger listens for timecode and must fire cues on time")
        log.info(.app, "app.app_nap_disabled", "App Nap disabled (latency-critical activity)")
    }

    /// While armed, stop the Mac from idle-sleeping (the display may still sleep).
    public func setPreventSleep(_ prevent: Bool) {
        if prevent, !holdingSleepAssertion {
            let status = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "TC Trigger is armed" as CFString, &sleepAssertion)
            if status == kIOReturnSuccess {
                holdingSleepAssertion = true
                log.info(.app, "app.sleep_prevented", "System sleep prevented while armed")
            } else {
                log.error(.app, "app.sleep_assertion_failed", "Could not prevent system sleep",
                          ["status": .int(Int(status))])
            }
        } else if !prevent, holdingSleepAssertion {
            IOPMAssertionRelease(sleepAssertion)
            holdingSleepAssertion = false
            log.info(.app, "app.sleep_allowed", "System sleep allowed again (disarmed)")
        }
    }

    public var isPreventingSleep: Bool { holdingSleepAssertion }

    // MARK: Launch at login

    public static var launchAtLoginStatus: SMAppService.Status { SMAppService.mainApp.status }

    public static var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message if it failed.
    public func setLaunchAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            log.info(.settings, "settings.changed", "Launch at login: \(!on) → \(on)",
                     ["setting": "launchAtLogin", "old": .bool(!on), "new": .bool(on), "source": "ui"])
            if on, SMAppService.mainApp.status == .requiresApproval {
                return "macOS needs you to allow TC Trigger in System Settings → General → Login Items."
            }
            return nil
        } catch {
            log.error(.app, "app.login_item_failed", "Could not \(on ? "enable" : "disable") launch at login: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}
