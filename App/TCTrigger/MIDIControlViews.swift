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
            LearnRow(title: "Armed LED", target: .feedback, trigger: model.settings.feedbackTrigger)
            HStack {
                Text("Sends 127 when armed and 0 when disarmed, using the learned note or CC.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Send Now", action: model.sendFeedbackTest)
                    .disabled(model.settings.feedbackTrigger == nil || !model.feedbackConnected)
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
