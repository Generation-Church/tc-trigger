import SwiftUI
import TCTriggerKit

/// Settings section: controller input, MIDI Learn for each action, LED feedback.
struct MIDIControlSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("MIDI control") {
            Picker("Controller input", selection: Binding(get: { model.settings.controlInputID },
                                                          set: { model.selectControlInput($0) })) {
                Text("None").tag(Int32?.none)
                ForEach(model.midiSources) { s in Text(s.name).tag(Int32?.some(s.uniqueID)) }
                if let id = model.settings.controlInputID, !model.midiSources.contains(where: { $0.uniqueID == id }) {
                    Text("\(model.settings.controlInputName ?? "Controller") — not connected").tag(Int32?.some(id))
                }
            }
            ForEach(ControlAction.allCases) { action in
                LearnRow(title: action.title, target: .action(action), trigger: model.settings.mappings[action])
            }
            Text("Click Learn, then press the button on your controller. TC Trigger works out whether it sends a press and a release or a single message per press, so one press never counts twice.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(model.midiController == nil)

        Section("Armed LED feedback") {
            Picker("Feedback output", selection: Binding(get: { model.settings.feedbackDestinationID },
                                                        set: { model.selectFeedbackOutput($0) })) {
                Text("None").tag(Int32?.none)
                ForEach(model.midiDestinations) { d in Text(d.name).tag(Int32?.some(d.uniqueID)) }
                if let id = model.settings.feedbackDestinationID, !model.midiDestinations.contains(where: { $0.uniqueID == id }) {
                    Text("\(model.settings.feedbackDestinationName ?? "Output") — not connected").tag(Int32?.some(id))
                }
            }
            Picker("LED message", selection: Binding(
                get: { model.settings.feedbackCustom != nil },
                set: { custom in model.setCustomFeedback(custom ? defaultCustom : nil) })) {
                Text("Echo the learned button (127 armed / 0 disarmed)").tag(false)
                Text("Custom messages").tag(true)
            }
            if let custom = model.settings.feedbackCustom {
                FeedbackMessageRow(title: "When armed", message: custom.armed) { m in
                    var c = custom; c.armed = m; model.setCustomFeedback(c)
                }
                FeedbackMessageRow(title: "When disarmed", message: custom.disarmed) { m in
                    var c = custom; c.disarmed = m; model.setCustomFeedback(c)
                }
                MorningstarFillRow()
                Text("Use custom messages when the controller expects something other than its button's own note or CC, e.g. a Morningstar switch's toggle state, or a colour value on a Launchpad or APC (green when armed, red when disarmed).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LearnRow(title: "Armed LED", target: .feedback, trigger: model.settings.feedbackTrigger)
                Text("Sends the learned note or CC: 127 when armed, 0 when disarmed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Sent when the armed state changes, at launch, and when the controller reconnects.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Send Now", action: model.sendFeedbackTest)
                    .disabled(!model.hasFeedbackMessage || !model.feedbackConnected)
            }
        }
    }

    /// Starting point when switching to custom: the learned button's message, else CC 1.
    private var defaultCustom: CustomFeedback {
        let t = model.settings.feedbackTrigger
        let kind: FeedbackMessage.Kind = t?.kind == .note ? .note : .cc
        let ch = t?.channel ?? 1, num = t?.number ?? 1
        return CustomFeedback(armed: FeedbackMessage(kind: kind, channel: ch, number: num, value: 127),
                              disarmed: FeedbackMessage(kind: kind, channel: ch, number: num, value: 0))
    }
}

/// One custom LED message: type (or nothing), channel, number, value.
struct FeedbackMessageRow: View {
    let title: String
    let message: FeedbackMessage?
    let set: (FeedbackMessage?) -> Void

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Picker("", selection: Binding<FeedbackMessage.Kind?>(
                    get: { message?.kind },
                    set: { kind in
                        guard let kind else { set(nil); return }
                        let m = message ?? FeedbackMessage(kind: kind, channel: 1, number: 0, value: 127)
                        set(FeedbackMessage(kind: kind, channel: m.channel, number: m.number, value: m.value))
                    })) {
                    Text("Nothing").tag(FeedbackMessage.Kind?.none)
                    ForEach(FeedbackMessage.Kind.allCases, id: \.self) { k in Text(k.title).tag(Optional(k)) }
                }
                .labelsHidden()
                .frame(width: 150)
                if let m = message {
                    Text("Ch").foregroundStyle(.secondary)
                    IntField(value: m.channel, range: 1...16) { v in
                        set(FeedbackMessage(kind: m.kind, channel: v, number: m.number, value: m.value))
                    }
                    .frame(width: 36)
                    Text(m.kind == .note ? "Note" : m.kind == .cc ? "CC" : "Program").foregroundStyle(.secondary)
                    IntField(value: m.number, range: 0...127) { v in
                        set(FeedbackMessage(kind: m.kind, channel: m.channel, number: v, value: m.value))
                    }
                    .frame(width: 40)
                    if m.kind != .programChange {
                        Text(m.kind == .note ? "Velocity" : "Value").foregroundStyle(.secondary)
                        IntField(value: m.value, range: 0...127) { v in
                            set(FeedbackMessage(kind: m.kind, channel: m.channel, number: m.number, value: v))
                        }
                        .frame(width: 40)
                    }
                }
            }
        }
    }
}

/// Fills both custom messages for a Morningstar MC6 / MC8 / MC10 switch (CC 2 / CC 3).
struct MorningstarFillRow: View {
    @EnvironmentObject var model: AppModel
    @State private var switchIndex = 0
    @State private var channel = 1

    var body: some View {
        LabeledContent("Morningstar MC6/MC8/MC10") {
            HStack(spacing: 6) {
                Text("Switch").foregroundStyle(.secondary)
                Picker("", selection: $switchIndex) {
                    ForEach(Array(CustomFeedback.morningstarSwitches.enumerated()), id: \.offset) { i, letter in
                        Text(letter).tag(i)
                    }
                }
                .labelsHidden()
                .frame(width: 60)
                Text("on its channel").foregroundStyle(.secondary)
                Picker("", selection: $channel) {
                    ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .frame(width: 60)
                Button("Fill In") {
                    model.setCustomFeedback(.morningstar(switchIndex: switchIndex, channel: channel))
                }
                .help("Armed → CC 2 (Engage Toggle), disarmed → CC 3 (Disengage Toggle), value = switch")
            }
        }
    }
}

struct LearnRow: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let target: AppModel.LearnTarget
    let trigger: MIDITrigger?

    var body: some View {
        let isLearning = model.learning == target
        LabeledContent(title) {
            HStack {
                if isLearning {
                    Text("Press the button now…").foregroundStyle(.orange)
                } else {
                    Text(trigger?.description ?? "Not set").foregroundStyle(trigger == nil ? .secondary : .primary)
                }
                Button(isLearning ? "Cancel" : "Learn") {
                    isLearning ? model.cancelLearn() : model.startLearn(target)
                }
                .disabled(!isLearning && (model.settings.controlInputID == nil || !model.controlInputConnected))
                .help(model.controlInputConnected ? "" : "Choose a connected controller input first")
                if trigger != nil && !isLearning {
                    Button { model.clearMapping(target) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .help("Clear")
                }
            }
        }
    }
}

/// Fire Next Cue and Panic.
struct ManualButtons: View {
    @EnvironmentObject var model: AppModel
    var compact = false

    var body: some View {
        HStack {
            Button {
                model.fireNext()
            } label: {
                Label(model.fireNextCue.map { "Fire Next: \($0.name)" } ?? "Fire Next (none)", systemImage: "forward.fill")
                    .lineLimit(1)
            }
            .disabled(model.fireNextCue == nil)
            .help("Send the next cue's note now, regardless of timecode and armed state")
            Spacer()
            Button(role: .destructive) {
                model.panic()
            } label: {
                Label("Panic", systemImage: "exclamationmark.octagon.fill")
            }
            .help("Note-offs for every cue note, All Notes Off on all channels, and cancel pending cues")
        }
        .controlSize(compact ? .small : .regular)
    }
}
