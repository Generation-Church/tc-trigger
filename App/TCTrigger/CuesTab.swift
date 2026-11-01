import AppKit
import SwiftUI
import TCTriggerKit
import UniformTypeIdentifiers

/// The cue list: edit in place, sorted by timecode, autosaved, with import/export.
struct CuesTab: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: Cue.ID?
    @State private var pendingDelete: Cue?
    @State private var pendingImport: URL?
    @State private var alertMessage: String?

    var body: some View {
        let warnings = CueWarnings.check(model.cues, rate: model.snapshot.rate)
        let nextID = model.snapshot.nextCue?.id

        VStack(spacing: 0) {
            Table(model.cues, selection: $selection) {
                TableColumn("On") { cue in
                    Toggle("", isOn: Binding(get: { cue.enabled }, set: { model.setEnabled($0, for: cue.id) }))
                        .labelsHidden()
                        .help(cue.enabled ? "Enabled — will fire" : "Disabled — will never fire")
                }
                .width(28)
                TableColumn("") { cue in
                    StatusIcon(isNext: cue.id == nextID, warnings: warnings[cue.id] ?? [])
                }
                .width(22)
                TableColumn("Name") { cue in
                    CommitTextField(text: cue.name) { new in
                        var c = cue; c.name = new; model.updateCue(c); return true
                    }
                    .opacity(cue.enabled ? 1 : 0.5)
                }
                TableColumn("Timecode") { cue in
                    CommitTextField(text: cue.timecode.description, monospaced: true) { new in
                        guard let tc = Timecode(string: new) else { return false }
                        var c = cue; c.timecode = tc; model.updateCue(c); return true
                    }
                    .help("HH:MM:SS:FF")
                }
                .width(104)
                TableColumn("Note") { cue in
                    HStack(spacing: 4) {
                        IntField(value: cue.note, range: 0...127) { var c = cue; c.note = $0; model.updateCue(c) }
                            .frame(width: 34)
                        NoteNameMenu(note: cue.note) { var c = cue; c.note = $0; model.updateCue(c) }
                    }
                }
                .width(104)
                TableColumn("Ch") { cue in
                    IntField(value: cue.channel, range: 1...16) { var c = cue; c.channel = $0; model.updateCue(c) }
                }
                .width(36)
                TableColumn("Vel") { cue in
                    IntField(value: cue.velocity, range: 1...127) { var c = cue; c.velocity = $0; model.updateCue(c) }
                }
                .width(40)
                TableColumn("") { cue in
                    Button("Test Fire") { model.testFire(cue) }
                        .controlSize(.small)
                        .help("Send this note now, ignoring timecode and the armed state")
                }
                .width(72)
            }
            .contextMenu(forSelectionType: Cue.ID.self) { ids in
                if let id = ids.first, let cue = model.cues.first(where: { $0.id == id }) {
                    Button("Test Fire") { model.testFire(cue) }
                    Button(cue.enabled ? "Disable" : "Enable") { model.setEnabled(!cue.enabled, for: id) }
                    Button("Duplicate") { model.duplicateCue(id) }
                    Divider()
                    Button("Delete…", role: .destructive) { pendingDelete = cue }
                }
            }
            .onDeleteCommand {
                if let id = selection { pendingDelete = model.cues.first { $0.id == id } }
            }

            Divider()
            HStack(spacing: 8) {
                Button { model.addCue() } label: { Label("Add", systemImage: "plus") }
                Button { if let id = selection { model.duplicateCue(id) } } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(selection == nil)
                Button { pendingDelete = model.cues.first { $0.id == selection } } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selection == nil)
                Spacer()
                Button("Import…", action: chooseImport)
                Button("Export…", action: export).disabled(model.cues.isEmpty)
            }
            .padding(10)
            Text("Sorted by timecode and saved automatically. Every LTC segment needs at least 2 seconds of pre-roll before its cue (more with a negative offset). Duplicated cues start disabled.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom], 10)
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let c = pendingDelete { model.deleteCue(c.id) }
                pendingDelete = nil
            }
        } message: {
            Text("This cue will no longer fire. The deletion is recorded in the log.")
        }
        .confirmationDialog("Replace the cue list?", isPresented: Binding(
            get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            Button("Replace \(model.cues.count) Cue\(model.cues.count == 1 ? "" : "s")", role: .destructive) {
                if let url = pendingImport { doImport(url) }
                pendingImport = nil
            }
        } message: {
            Text("Importing \(pendingImport?.lastPathComponent ?? "") replaces all current cues. Export first if you want to keep them.")
        }
        .alert("Cue list", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a TC Trigger cue list (.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if model.cues.isEmpty { doImport(url) } else { pendingImport = url }
    }

    private func doImport(_ url: URL) {
        do {
            try model.importCues(from: url)
        } catch {
            alertMessage = "Couldn't import \(url.lastPathComponent). Nothing was changed.\n\n\(error)"
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = CueTransfer.suggestedFileName(campus: model.settings.campusName)
        panel.message = "Export the cue list to load at another campus"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportCues(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            alertMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }
}

/// The note name ("C3", "A#0") as a dropdown of all 128 MIDI notes, grouped by octave.
/// Names follow Ableton (C3 = 60), so they match what Ableton shows when mapping.
struct NoteNameMenu: View {
    let note: Int
    let select: (Int) -> Void

    var body: some View {
        Menu {
            ForEach(Self.octaves, id: \.self) { octave in
                let notes = Array(max(0, (octave + 2) * 12)...min(127, (octave + 2) * 12 + 11))
                Menu("Octave \(octave)  (\(Cue.noteName(notes.first!))–\(Cue.noteName(notes.last!)))") {
                    Picker("", selection: Binding(get: { note }, set: { select($0) })) {
                        ForEach(notes, id: \.self) { n in
                            Text("\(Cue.noteName(n))   (\(n))").tag(n)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        } label: {
            Text(Cue.noteName(note)).monospaced()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the note by name (C3 = MIDI note 60, as in Ableton)")
    }

    /// Ableton numbers octaves from −2 (notes 0–11) to 8 (notes 120–127).
    static let octaves = Array(-2...8)
}

/// ▶ for the next cue, ⚠️ when something about the cue looks wrong (hover for details).
struct StatusIcon: View {
    let isNext: Bool
    let warnings: [String]

    var body: some View {
        if !warnings.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .help(warnings.joined(separator: "\n"))
        } else if isNext {
            Image(systemName: "play.fill")
                .foregroundStyle(.blue)
                .help("Next cue")
        }
    }
}

/// A text field that commits on Return or when focus leaves; reverts (with a beep) if
/// `commit` returns false.
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
