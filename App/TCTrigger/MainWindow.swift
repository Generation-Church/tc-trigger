import SwiftUI
import TCTriggerKit

struct MainWindow: View {
    static let id = "main"
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            ScrollView {
                StatusPanel()
                    .padding(20)
            }
            .tabItem { Label("Status", systemImage: "waveform") }

            CuesTab()
                .tabItem { Label("Cues", systemImage: "list.number") }

            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }

            LogsTab()
                .tabItem { Label("Logs", systemImage: "list.bullet.rectangle") }
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

/// Menu-bar drop-down panel.
struct MenuBarPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// One click for a volunteer: last 7 days → Desktop → shown in Finder.
    private func exportLogs() {
        Task {
            do {
                let url = try await model.exportLogs(days: 7)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't export logs"
                alert.informativeText = "\(error)"
                alert.runModal()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusPanel(compact: true)
            Divider()
            HStack {
                Button("Open TC Trigger…") {
                    openWindow(id: MainWindow.id)
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Export Logs") { exportLogs() }
                    .help("Save the last 7 days of logs to the Desktop as a zip")
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

struct SettingsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var campusDraft = ""
    @State private var offsetDraft = 0.0
    @State private var showCalibration = false

    var body: some View {
        Form {
            Section("General") {
                TextField("Campus name", text: $campusDraft, prompt: Text("e.g. Queen Creek"))
                    .onSubmit(commitCampus)
                Text("Shown in the app and written into every log line, so exported logs say which Mac they came from.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Audio input (LTC)") {
                Picker("Device", selection: deviceBinding) {
                    Text("System default input").tag(String?.none)
                    ForEach(model.devices) { d in
                        Text("\(d.name) (\(d.inputChannels) in)").tag(String?.some(d.uid))
                    }
                    if let uid = model.settings.audioDeviceUID, !model.devices.contains(where: { $0.uid == uid }) {
                        Text("\(model.settings.audioDeviceName ?? uid) — not connected").tag(String?.some(uid))
                    }
                }
                Picker("Channel", selection: channelBinding) {
                    ForEach(1...max(1, channelCount), id: \.self) { ch in
                        Text("Input \(ch)").tag(ch)
                    }
                }
                LevelMeter(db: model.snapshot.inputLevelDb)
                Text("TC Trigger listens alongside Ableton and never changes the interface's sample rate or buffer size.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Timing") {
                LabeledContent("Offset") {
                    HStack {
                        Slider(value: $offsetDraft, in: Double(AppSettings.offsetRange.lowerBound)...Double(AppSettings.offsetRange.upperBound), step: 1) { editing in
                            if !editing { commitOffset() }
                        }
                        Stepper("", value: Binding(get: { Int(offsetDraft) }, set: { offsetDraft = Double($0); commitOffset() }),
                                in: AppSettings.offsetRange, step: 1)
                            .labelsHidden()
                        Text("\(Int(offsetDraft) > 0 ? "+" : "")\(Int(offsetDraft)) ms")
                            .monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                Text("Positive fires later, negative fires earlier. Negative offsets work because TC Trigger predicts the cue frame from the LTC before it, so every LTC segment needs pre-roll before its cue: at least 2 seconds, plus the size of any negative offset.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: Binding(get: { model.settings.catchWindowFrames },
                                       set: { v in model.updateSettings { $0.catchWindowFrames = v } }),
                        in: AppSettings.catchWindowRange) {
                    LabeledContent("Catch window", value: "\(model.settings.catchWindowFrames) frames")
                }
                Text("If the exact cue frame is lost (a codec glitch), still fire when LTC returns within this many frames after the cue. Later than that never fires.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Measure with a loopback cable") {
                    Button("Calibrate Offset…") { showCalibration = true }
                }
            }

            Section("MIDI") {
                LabeledContent("Output", value: model.midiStatus)
                Text("In Ableton: Settings → Link, Tempo & MIDI → turn on Remote for the “TC Trigger” input, then MIDI-map each song’s scene launch to its cue’s note. Set those scenes’ launch quantization to None.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            MIDIControlSection()

            Section("Startup") {
                Toggle("Launch TC Trigger at login", isOn: Binding(get: { model.launchAtLogin },
                                                                   set: { model.setLaunchAtLogin($0) }))
                if let msg = model.launchAtLoginMessage {
                    Text(msg).font(.caption).foregroundStyle(.orange)
                }
                Text("While armed, TC Trigger keeps the Mac from going to sleep (the display can still sleep). App Nap is always off for TC Trigger.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Files") {
                LabeledContent("Logs") {
                    Button("Show in Finder") { NSWorkspace.shared.open(model.log.directory) }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showCalibration) { CalibrationSheet(isPresented: $showCalibration) }
        .onChange(of: model.settings.offsetMs) { _, v in offsetDraft = Double(v) }
        .onAppear {
            campusDraft = model.settings.campusName
            offsetDraft = Double(model.settings.offsetMs)
        }
        .onDisappear(perform: commitCampus)
    }

    private func commitOffset() {
        let v = Int(offsetDraft)
        if v != model.settings.offsetMs { model.updateSettings { $0.offsetMs = v } }
    }

    private var channelCount: Int { model.selectedDevice?.inputChannels ?? model.settings.audioChannel }

    private func commitCampus() {
        let name = campusDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name != model.settings.campusName { model.updateSettings { $0.campusName = name } }
    }

    private var deviceBinding: Binding<String?> {
        Binding(get: { model.settings.audioDeviceUID }, set: { model.selectDevice(uid: $0) })
    }

    private var channelBinding: Binding<Int> {
        Binding(get: { model.settings.audioChannel }, set: { ch in model.updateSettings { $0.audioChannel = ch } })
    }
}
