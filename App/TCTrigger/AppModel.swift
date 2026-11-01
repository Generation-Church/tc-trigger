import AppKit
import AVFoundation
import Combine
import TCTriggerKit

/// Glue between the engine (which runs on its own threads) and the SwiftUI views.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let log: EventLog
    let settingsStore: SettingsStore
    let engine: LTCEngine

    @Published private(set) var settings: AppSettings
    @Published private(set) var snapshot = EngineSnapshot()
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var micPermission: AVAuthorizationStatus
    @Published private(set) var recentLog: [LogEntry] = []

    private var uiTimer: Timer?
    private var deviceTimer: Timer?

    private init() {
        log = EventLog()
        settingsStore = SettingsStore(log: log)
        let initial = settingsStore.settings
        settings = initial
        log.campus = initial.campusName
        engine = LTCEngine(log: log)
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)

        log.info(.app, "app.launch", "TC Trigger \(SystemInfo.appVersion) started",
                 ["app_version": .string(SystemInfo.appVersion), "macos": .string(SystemInfo.macOSVersion),
                  "mac_model": .string(SystemInfo.macModel), "host": .string(SystemInfo.hostName),
                  "campus": .string(initial.campusName), "log_dir": .string(log.directory.path)])

        recentLog = log.recent().reversed()
        log.addObserver { [weak self] entry in
            DispatchQueue.main.async { self?.appendLog(entry) }
        }
        settingsStore.onChange = { [weak self] s in self?.settingsChanged(s) }

        refreshDevices()
        engine.configure(deviceUID: settings.audioDeviceUID, deviceName: settings.audioDeviceName,
                         channel: settings.audioChannel)
        startAudioIfPermitted()

        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSnapshot() }
        }
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willQuit() }
        }
    }

    // MARK: Actions from the UI

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        settingsStore.update(source: "ui", change)
    }

    func selectDevice(uid: String?) {
        let name = uid.flatMap { u in devices.first { $0.uid == u }?.name }
        updateSettings {
            $0.audioDeviceUID = uid
            $0.audioDeviceName = name
            if let d = devices.first(where: { $0.uid == uid }), $0.audioChannel > d.inputChannels {
                $0.audioChannel = 1
            }
        }
    }

    func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
                if granted {
                    self.log.info(.audio, "audio.permission_granted", "Microphone (audio input) access granted")
                    self.engine.start()
                } else {
                    self.log.error(.audio, "audio.permission_denied", "Microphone (audio input) access denied")
                }
            }
        }
    }

    func openMicrophonePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The device the current settings point at (nil = system default input).
    var selectedDevice: AudioInputDevice? {
        if let uid = settings.audioDeviceUID { return devices.first { $0.uid == uid } }
        return AudioDevices.defaultInputDeviceID().flatMap { id in devices.first { $0.deviceID == id } }
    }

    // MARK: Private

    private func startAudioIfPermitted() {
        switch micPermission {
        case .authorized: engine.start()
        case .notDetermined: requestMicrophoneAccess()
        default:
            log.error(.audio, "audio.permission_denied",
                      "Microphone (audio input) access is off; enable it in System Settings → Privacy & Security → Microphone")
        }
    }

    private func settingsChanged(_ s: AppSettings) {
        let old = settings
        settings = s
        log.campus = s.campusName
        if old.audioDeviceUID != s.audioDeviceUID || old.audioChannel != s.audioChannel {
            engine.configure(deviceUID: s.audioDeviceUID, deviceName: s.audioDeviceName, channel: s.audioChannel)
        }
    }

    private func refreshSnapshot() {
        let s = engine.snapshot()
        if s != snapshot { snapshot = s }
    }

    private func refreshDevices() {
        let d = AudioDevices.inputDevices()
        if d != devices { devices = d }
    }

    private func appendLog(_ entry: LogEntry) {
        recentLog.insert(entry, at: 0)
        if recentLog.count > 1000 { recentLog.removeLast(recentLog.count - 1000) }
    }

    private func willQuit() {
        log.info(.app, "app.quit", "TC Trigger quit")
        engine.stop()
        log.flush()
    }
}
