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

            RecentLogTab()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}

/// Menu-bar drop-down panel.
struct MenuBarPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

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
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

struct SettingsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var campusDraft = ""
    @State private var offsetDraft = 0.0

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
            }

            Section("MIDI") {
                LabeledContent("Output", value: model.midiStatus)
                Text("In Ableton: Settings → Link, Tempo & MIDI → turn on Remote for the “TC Trigger” input, then MIDI-map each song’s scene launch to its cue’s note. Set those scenes’ launch quantization to None.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Files") {
                LabeledContent("Logs") {
                    Button("Show in Finder") { NSWorkspace.shared.open(model.log.directory) }
                }
            }
        }
        .formStyle(.grouped)
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

/// Simple live log for M1 (the full viewer with filters and export arrives in M5).
struct RecentLogTab: View {
    @EnvironmentObject var model: AppModel
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        List(model.recentLog) { e in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.time.string(from: e.timestamp)).monospacedDigit().foregroundStyle(.secondary)
                Text(e.category.rawValue).font(.caption.weight(.semibold)).frame(width: 56, alignment: .leading)
                Text(e.message).textSelection(.enabled)
            }
            .font(.callout)
            .listRowBackground(color(for: e))
        }
    }

    private func color(for e: LogEntry) -> Color {
        switch e.level {
        case .error: return .red.opacity(0.15)
        case .warning: return .yellow.opacity(0.18)
        default: return .clear
        }
    }
}
