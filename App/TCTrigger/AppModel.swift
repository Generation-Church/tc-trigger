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
    let midiController: MIDIController?
    private let interpreter = ControlInterpreter()

    /// What MIDI Learn is currently waiting for.
    enum LearnTarget: Equatable { case action(ControlAction), feedback }

    @Published private(set) var settings: AppSettings
    @Published private(set) var snapshot = EngineSnapshot()
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var micPermission: AVAuthorizationStatus
    @Published private(set) var recentLog: [LogEntry] = []
    @Published private(set) var cues: [Cue] = []
    @Published private(set) var midiStatus: String
    @Published private(set) var midiSources: [MIDIEndpointInfo] = []
    @Published private(set) var midiDestinations: [MIDIEndpointInfo] = []
    @Published private(set) var learning: LearnTarget?
    @Published private(set) var controlInputConnected = false
    @Published private(set) var feedbackConnected = false
    private var learnSession = LearnSession()
    private var maintenanceTimer: Timer?
    let reliability: Reliability
    @Published private(set) var launchAtLogin = Reliability.launchAtLoginEnabled
    @Published var launchAtLoginMessage: String?
    private var learnTimer: Timer?

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
        midiController = try? MIDIController(ownSourceName: "TC Trigger")
        reliability = Reliability(log: log)

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
        reliability.disableAppNap()
        reliability.setPreventSleep(initial.armed)
        setUpMIDIControl(initial)
        log.verbose = initial.isVerbose()
        if log.verbose, let until = initial.verboseUntil {
            log.info(.app, "log.verbose_on", "Verbose logging is on until \(until.formatted(date: .abbreviated, time: .shortened))")
        }
        runMaintenance()
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runMaintenance() }
        }

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

    func setArmed(_ armed: Bool, source: String = "ui") {
        engine.setArmed(armed, source: source)
        settingsStore.update(source: source) { $0.armed = armed }
        reliability.setPreventSleep(armed)
        sendFeedback(armed: armed)
    }

    func fireNext(source: String = "ui") { engine.fireNext(source: source) }

    func panic(source: String = "ui") { engine.panic(source: source) }

    /// The cue Fire Next would send now.
    var fireNextCue: Cue? { nextCueToFire(after: snapshot.lastFireCueIDForNext, in: cues) }

    // MARK: MIDI control

    func selectControlInput(_ id: Int32?) {
        let name = midiSources.first { $0.uniqueID == id }?.name
        updateSettings { $0.controlInputID = id; $0.controlInputName = name }
        midiController?.selectInput(id: id, name: name)
        refreshMIDIStatus(logChanges: true)
    }

    func selectFeedbackOutput(_ id: Int32?) {
        let name = midiDestinations.first { $0.uniqueID == id }?.name
        updateSettings { $0.feedbackDestinationID = id; $0.feedbackDestinationName = name }
        midiController?.selectOutput(id: id, name: name)
        refreshMIDIStatus(logChanges: true)
        sendFeedback(armed: settings.armed)
    }

    func startLearn(_ target: LearnTarget) {
        learnSession = LearnSession()
        learning = target
        learnTimer?.invalidate()
        learnTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let t = self.learnSession.finish(at: ProcessInfo.processInfo.systemUptime) else { return }
                self.finishLearn(t)
            }
        }
    }

    func cancelLearn() {
        learning = nil
        learnTimer?.invalidate()
    }

    func clearMapping(_ target: LearnTarget) {
        switch target {
        case .action(let a): updateSettings { $0.controlMappings[a.rawValue] = nil }
        case .feedback: updateSettings { $0.feedbackTrigger = nil }
        }
        interpreter.mappings = settings.mappings
    }

    func sendFeedbackTest() { sendFeedback(armed: settings.armed) }

    // MARK: Reliability and calibration

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLoginMessage = reliability.setLaunchAtLogin(on)
        launchAtLogin = Reliability.launchAtLoginEnabled
    }

    func setShowInDock(_ on: Bool) {
        updateSettings { $0.showInDock = on }
        applyDockSetting()
    }

    func applyDockSetting() {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
        if settings.showInDock { NSApp.activate(ignoringOtherApps: false) }
    }

    func startCalibration(clickChannel: Int) { engine.setCalibration(clickChannel: clickChannel) }

    func stopCalibration() { engine.setCalibration(clickChannel: nil) }

    func applyCalibratedOffset(_ ms: Int) {
        updateSettings { $0.offsetMs = ms }
        log.info(.audio, "cal.applied", "Offset set to \(ms) ms from calibration", ["offset_ms": .int(ms)])
    }

    // MARK: Logging

    var verboseOn: Bool { settings.isVerbose() }

    func setVerbose(_ on: Bool) {
        let until = on ? Date().addingTimeInterval(AppSettings.verboseDuration) : nil
        updateSettings { $0.verboseUntil = until }
        log.verbose = on
        log.info(.app, on ? "log.verbose_on" : "log.verbose_off",
                 on ? "Verbose logging turned on for 24 hours" : "Verbose logging turned off",
                 ["source": "ui"])
    }

    /// A manual note in the log, e.g. "band said Song 2 felt late".
    func addMark(_ text: String) {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        log.info(.app, "app.mark", "MARK: \(note)", ["note": .string(note), "tc": .string(snapshot.timecode?.description ?? ""),
                                                     "lock": .string(snapshot.lockState.rawValue)])
    }

    /// Builds the troubleshooting zip on the Desktop and returns its URL.
    func exportLogs(days: Int) async throws -> URL {
        log.info(.app, "log.export", "Exporting logs (last \(days) days)", ["days": .int(days)])
        log.flush()
        var o = LogExport.Options(campus: settings.campusName, logDirectory: log.directory,
                                  settingsFile: settingsStore.fileURL, cuesFile: cueStore.fileURL,
                                  destinationFolder: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0])
        o.days = days
        let options = o
        let url = try await Task.detached { try LogExport.export(options) }.value
        log.info(.app, "log.exported", "Logs exported to \(url.lastPathComponent)", ["path": .string(url.path), "days": .int(days)])
        return url
    }

    /// Verbose auto-off and log retention (every minute; retention is cheap when nothing is due).
    private func runMaintenance() {
        if log.verbose, !settings.isVerbose() {
            log.verbose = false
            log.info(.app, "log.verbose_off", "Verbose logging turned itself off after 24 hours", ["source": "auto"])
            updateSettings { $0.verboseUntil = nil }
        }
        let dir = log.directory
        let log = self.log
        DispatchQueue.global(qos: .utility).async {
            let deleted = LogFiles.prune(directory: dir)
            guard !deleted.isEmpty else { return }
            let mb = Double(deleted.reduce(0) { $0 + $1.size }) / 1_048_576
            log.info(.app, "log.pruned", "Deleted \(deleted.count) old log file\(deleted.count == 1 ? "" : "s") (\(String(format: "%.1f", mb)) MB)",
                     ["files": .string(deleted.map(\.day).joined(separator: ", ")), "megabytes": .double(mb)])
        }
    }

    private func setUpMIDIControl(_ s: AppSettings) {
        interpreter.mappings = s.mappings
        guard let mc = midiController else {
            log.error(.midi, "midi.control_failed", "Could not set up MIDI control input/output")
            return
        }
        mc.onMessage = { [weak self] m in self?.handleControlMessage(m) }
        mc.onSetupChanged = { [weak self] in self?.refreshMIDIStatus(logChanges: true) }
        mc.selectInput(id: s.controlInputID, name: s.controlInputName)
        mc.selectOutput(id: s.feedbackDestinationID, name: s.feedbackDestinationName)
        refreshMIDIStatus(logChanges: true)
        sendFeedback(armed: s.armed)
    }

    private func refreshMIDIStatus(logChanges: Bool) {
        guard let mc = midiController else { return }
        midiSources = mc.sources()
        midiDestinations = mc.destinations()
        let inNow = mc.connectedInput != nil, outNow = mc.connectedOutput != nil
        if logChanges, inNow != controlInputConnected, settings.controlInputID != nil {
            let name = settings.controlInputName ?? "controller"
            if inNow { log.info(.midi, "midi.control_connected", "MIDI controller connected: \(name)", ["device": .string(name)]) }
            else { log.warning(.midi, "midi.control_disconnected", "MIDI controller disconnected: \(name)", ["device": .string(name)]) }
        }
        if logChanges, outNow != feedbackConnected, settings.feedbackDestinationID != nil {
            let name = settings.feedbackDestinationName ?? "feedback output"
            if outNow {
                log.info(.midi, "midi.feedback_connected", "LED feedback output connected: \(name)", ["device": .string(name)])
            } else {
                log.warning(.midi, "midi.feedback_disconnected", "LED feedback output disconnected: \(name)", ["device": .string(name)])
            }
        }
        let reconnectedOut = outNow && !feedbackConnected
        controlInputConnected = inNow
        feedbackConnected = outNow
        if reconnectedOut { sendFeedback(armed: settings.armed) }
    }

    private func handleControlMessage(_ m: MIDIMessage) {
        let now = ProcessInfo.processInfo.systemUptime
        log.debug(.midi, "midi.in", "MIDI in: \(m)", ["bytes": .string(m.hex), "device": .string(settings.controlInputName ?? "")])
        if learning != nil {
            if let t = learnSession.feed(m, at: now) { finishLearn(t) }
            return
        }
        for action in interpreter.handle(m, at: now) {
            log.info(.midi, "midi.control", "MIDI control: \(action.title) (\(m))",
                     ["action": .string(action.rawValue), "message": .string(m.description)])
            switch action {
            case .toggleArm: setArmed(!settings.armed, source: "midi")
            case .arm: setArmed(true, source: "midi")
            case .disarm: setArmed(false, source: "midi")
            case .fireNext: fireNext(source: "midi")
            case .panic: panic(source: "midi")
            }
        }
    }

    private func finishLearn(_ t: MIDITrigger) {
        guard let target = learning else { return }
        learnTimer?.invalidate()
        learning = nil
        switch target {
        case .action(let action):
            updateSettings { s in
                // One control drives one action: take it away from any other action.
                for (k, v) in s.controlMappings where k != action.rawValue && v.kind == t.kind && v.channel == t.channel && v.number == t.number {
                    s.controlMappings[k] = nil
                }
                s.controlMappings[action.rawValue] = t
            }
            interpreter.mappings = settings.mappings
            log.info(.midi, "midi.learned", "Learned \(action.title): \(t)", ["action": .string(action.rawValue), "control": .string(t.description)])
        case .feedback:
            updateSettings { $0.feedbackTrigger = t }
            log.info(.midi, "midi.learned", "Learned LED feedback: \(t)", ["action": "feedback", "control": .string(t.description)])
            sendFeedback(armed: settings.armed)
        }
    }

    private func sendFeedback(armed: Bool) {
        guard let t = settings.feedbackTrigger, let mc = midiController, mc.connectedOutput != nil else { return }
        let m = MIDIMessages.feedback(t, armed: armed)
        let ok = mc.sendFeedback(m)
        log.debug(.midi, "midi.out", "MIDI out (LED feedback): \(m)", ["bytes": .string(m.hex), "ok": .bool(ok),
                                                                           "device": .string(settings.feedbackDestinationName ?? "")])
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
