import SwiftUI
import TCTriggerKit

/// Basic cue table (M2). M3 adds duplicate, import/export and more validation.
struct CuesTab: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: Cue.ID?

    var body: some View {
        VStack(spacing: 0) {
            Table(model.cues, selection: $selection) {
                TableColumn("On") { cue in
                    Toggle("", isOn: binding(cue, \.enabled)).labelsHidden()
                }
                .width(30)
                TableColumn("Name") { cue in
                    CommitTextField(text: cue.name) { new in
                        var c = cue; c.name = new; model.updateCue(c); return true
                    }
                }
                TableColumn("Timecode") { cue in
                    CommitTextField(text: cue.timecode.description, monospaced: true) { new in
                        guard let tc = Timecode(string: new) else { return false }
                        var c = cue; c.timecode = tc; model.updateCue(c); return true
                    }
                }
                .width(110)
                TableColumn("Note") { cue in
                    HStack(spacing: 4) {
                        IntField(value: cue.note, range: 0...127) { var c = cue; c.note = $0; model.updateCue(c) }
                        Text(Cue.noteName(cue.note)).foregroundStyle(.secondary).font(.caption)
                    }
                }
                .width(80)
                TableColumn("Ch") { cue in
                    IntField(value: cue.channel, range: 1...16) { var c = cue; c.channel = $0; model.updateCue(c) }
                }
                .width(40)
                TableColumn("Vel") { cue in
                    IntField(value: cue.velocity, range: 1...127) { var c = cue; c.velocity = $0; model.updateCue(c) }
                }
                .width(44)
                TableColumn("") { cue in
                    HStack {
                        Button("Test Fire") { model.testFire(cue) }
                            .help("Send this note now, ignoring timecode and the armed state")
                        Button(role: .destructive) { model.deleteCue(cue.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete cue")
                    }
                }
                .width(120)
            }
            Divider()
            HStack {
                Button { model.addCue() } label: { Label("Add Cue", systemImage: "plus") }
                Spacer()
                Text("Cues are sorted by timecode and saved automatically. Each LTC segment needs at least 2 seconds of pre-roll before its cue.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(10)
        }
    }

    private func binding(_ cue: Cue, _ key: WritableKeyPath<Cue, Bool>) -> Binding<Bool> {
        Binding(get: { cue[keyPath: key] }, set: { v in var c = cue; c[keyPath: key] = v; model.updateCue(c) })
    }
}

/// A text field that commits on Return or when focus leaves; reverts if `commit` returns false.
struct CommitTextField: View {
    let text: String
    var monospaced = false
    let commit: (String) -> Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .font(monospaced ? .body.monospaced() : .body)
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { _, new in if !focused { draft = new } }
            .onSubmit(apply)
            .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
    }

    private func apply() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed != text else { return }
        if !commit(trimmed) {
            NSSound.beep()
            draft = text
        }
    }
}

struct IntField: View {
    let value: Int
    let range: ClosedRange<Int>
    let commit: (Int) -> Void

    var body: some View {
        CommitTextField(text: String(value)) { s in
            guard let v = Int(s), range.contains(v) else { return false }
            commit(v)
            return true
        }
    }
}
