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
    let cueStore: CueStore
    let engine: LTCEngine
    private let midiSource: VirtualMIDISource?

    @Published private(set) var settings: AppSettings
    @Published private(set) var snapshot = EngineSnapshot()
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var micPermission: AVAuthorizationStatus
    @Published private(set) var recentLog: [LogEntry] = []
    @Published private(set) var cues: [Cue] = []
    @Published private(set) var midiStatus: String

    private var uiTimer: Timer?
    private var deviceTimer: Timer?

    private init() {
        log = EventLog()
        settingsStore = SettingsStore(log: log)
        let initial = settingsStore.settings
        settings = initial
        log.campus = initial.campusName
        cueStore = CueStore(log: log)
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)

        var midiError: String?
        do {
            midiSource = try VirtualMIDISource(name: "TC Trigger", uniqueID: initial.midiSourceUniqueID)
        } catch {
            midiSource = nil
            midiError = "\(error)"
        }
        midiStatus = midiSource != nil ? "Virtual MIDI source “TC Trigger” is available" : "MIDI source unavailable: \(midiError ?? "")"
        engine = LTCEngine(log: log, midi: midiSource)

        log.info(.app, "app.launch", "TC Trigger \(SystemInfo.appVersion) started",
                 ["app_version": .string(SystemInfo.appVersion), "macos": .string(SystemInfo.macOSVersion),
                  "mac_model": .string(SystemInfo.macModel), "host": .string(SystemInfo.hostName),
                  "campus": .string(initial.campusName), "log_dir": .string(log.directory.path)])

        if let midiError {
            log.error(.midi, "midi.source_failed", "Could not create the TC Trigger MIDI source: \(midiError)")
        } else if let src = midiSource {
            log.info(.midi, "midi.source_created", "Virtual MIDI source “TC Trigger” created", ["unique_id": .int(Int(src.uniqueID))])
            if initial.midiSourceUniqueID != src.uniqueID {
                settingsStore.update(source: "app") { $0.midiSourceUniqueID = src.uniqueID }
            }
        }

        recentLog = log.recent().reversed()
        log.addObserver { [weak self] entry in
            DispatchQueue.main.async { self?.appendLog(entry) }
        }
        settingsStore.onChange = { [weak self] s in self?.settingsChanged(s) }
        cues = cueStore.cues
        cueStore.onChange = { [weak self] c in
            self?.cues = c
            self?.engine.setCues(c)
        }
        engine.setCues(cues)
        engine.setTiming(offsetMs: initial.offsetMs, catchWindowFrames: initial.catchWindowFrames)
        engine.setArmed(initial.armed, source: "app launch")

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

    // MARK: Arming and cues

    func setArmed(_ armed: Bool) {
        engine.setArmed(armed, source: "ui")
        settingsStore.update(source: "ui") { $0.armed = armed }
    }

    func addCue() {
        let last = cues.last
        let tc = last.map { Timecode(frameIndex: $0.timecode.frameIndex(nominal: 30, dropFrame: false) + 30 * 60, nominal: 30, dropFrame: false) }
            ?? Timecode(1, 0, 0, 0)
        let cue = Cue(name: "Song \(cues.count + 1)", timecode: tc, note: min(127, (last?.note ?? 59) + 1),
                      channel: last?.channel ?? 1, velocity: last?.velocity ?? 127)
        cueStore.update { $0.append(cue) }
    }

    func updateCue(_ cue: Cue) {
        cueStore.update { list in
            if let i = list.firstIndex(where: { $0.id == cue.id }) { list[i] = cue }
        }
    }

    func deleteCue(_ id: UUID) {
        cueStore.update { $0.removeAll { $0.id == id } }
    }

    func duplicateCue(_ id: UUID) {
        guard let original = cues.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID()
        copy.name = original.name + " (copy)"
        copy.enabled = false // a copy at the same timecode would double-fire until edited
        cueStore.update { $0.append(copy) }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard var cue = cues.first(where: { $0.id == id }) else { return }
        cue.enabled = enabled
        updateCue(cue)
    }

    func importCues(from url: URL) throws {
        try cueStore.importFile(url)
    }

    func exportCues(to url: URL) throws {
        try cueStore.exportFile(url)
    }

    func testFire(_ cue: Cue) { engine.testFire(cue) }

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
        if old.offsetMs != s.offsetMs || old.catchWindowFrames != s.catchWindowFrames {
            engine.setTiming(offsetMs: s.offsetMs, catchWindowFrames: s.catchWindowFrames)
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
