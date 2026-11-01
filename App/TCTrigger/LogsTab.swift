import AppKit
import SwiftUI
import TCTriggerKit

/// The Logs tab: live view (newest first), filters, highlights, Mark, Verbose and Export.
struct LogsTab: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var viewer = LogViewerModel()
    @State private var selection: LogEntry.ID?
    @State private var showMark = false
    @State private var showExport = false

    var body: some View {
        VStack(spacing: 0) {
            filterBar.padding(10)
            Divider()
            List(viewer.filtered, selection: $selection) { e in
                LogRow(entry: e)
                    .listRowBackground(LogRow.highlight(e))
                    .tag(e.id)
            }
            .listStyle(.plain)
            .overlay {
                if viewer.loading { ProgressView() }
                else if viewer.filtered.isEmpty { Text("No log entries match.").foregroundStyle(.secondary) }
            }
            if let id = selection, let e = viewer.filtered.first(where: { $0.id == id }) {
                Divider()
                LogDetail(entry: e).frame(height: 130)
            }
            Divider()
            footer.padding(10)
        }
        .onAppear { viewer.attach(model) }
        .onChange(of: model.recentLog.first?.id) { _, _ in viewer.appendLive(from: model.recentLog) }
        .sheet(isPresented: $showMark) { MarkSheet(isPresented: $showMark) }
        .sheet(isPresented: $showExport) { ExportSheet(isPresented: $showExport) }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("Level", selection: $viewer.minLevel) {
                Text("All levels").tag(LogLevel.debug)
                Text("Info and up").tag(LogLevel.info)
                Text("Warnings and errors").tag(LogLevel.warning)
                Text("Errors only").tag(LogLevel.error)
            }
            .labelsHidden()
            .frame(width: 160)

            Menu(viewer.categories.count == LogCategory.allCases.count ? "All categories" : "\(viewer.categories.count) categories") {
                ForEach(LogCategory.allCases, id: \.self) { c in
                    Toggle(c.rawValue, isOn: Binding(get: { viewer.categories.contains(c) },
                                                     set: { on in if on { viewer.categories.insert(c) } else { viewer.categories.remove(c) } }))
                }
                Divider()
                Button("Show all") { viewer.categories = Set(LogCategory.allCases) }
            }
            .frame(width: 130)

            Picker("Range", selection: $viewer.range) {
                ForEach(LogViewerModel.Range.allCases) { r in Text(r.title).tag(r) }
            }
            .labelsHidden()
            .frame(width: 130)
            if viewer.range == .custom {
                DatePicker("", selection: $viewer.customFrom, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                Text("to")
                DatePicker("", selection: $viewer.customTo, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
            }
            TextField("Search", text: $viewer.search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Verbose", isOn: Binding(get: { model.verboseOn }, set: { model.setVerbose($0) }))
                .toggleStyle(.switch)
                .help("Adds signal levels, decode statistics, timing measurements and raw MIDI. Turns itself off after 24 hours.")
            if let until = model.settings.verboseUntil, model.verboseOn {
                Text("until \(until.formatted(date: .omitted, time: .shortened)) \(Calendar.current.isDateInToday(until) ? "today" : "tomorrow"), then off automatically")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(viewer.filtered.count) entr\(viewer.filtered.count == 1 ? "y" : "ies")")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button { showMark = true } label: { Label("Mark…", systemImage: "bookmark") }
                .help("Add a note to the log, e.g. “band said Song 2 felt late”")
            Button { showExport = true } label: { Label("Export Logs…", systemImage: "square.and.arrow.up") }
        }
    }
}

@MainActor
final class LogViewerModel: ObservableObject {
    enum Range: String, CaseIterable, Identifiable {
        case today, last24h, last7d, last90d, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: return "Today"
            case .last24h: return "Last 24 hours"
            case .last7d: return "Last 7 days"
            case .last90d: return "Last 90 days"
            case .custom: return "Custom…"
            }
        }
    }

    @Published var minLevel: LogLevel = .info { didSet { refilter() } }
    @Published var categories = Set(LogCategory.allCases) { didSet { refilter() } }
    @Published var search = "" { didSet { refilter() } }
    @Published var range: Range = .today { didSet { reload() } }
    @Published var customFrom = Calendar.current.date(byAdding: .day, value: -1, to: Date())! { didSet { if range == .custom { reload() } } }
    @Published var customTo = Date() { didSet { if range == .custom { reload() } } }
    @Published private(set) var filtered: [LogEntry] = []
    @Published private(set) var loading = false

    private var entries: [LogEntry] = [] // oldest first
    private var directory: URL?
    private var lastSeen: Date = .distantPast

    func attach(_ model: AppModel) {
        guard directory == nil else { return }
        directory = model.log.directory
        model.log.flush()
        reload()
    }

    private var bounds: (from: Date, to: Date, live: Bool) {
        let now = Date()
        switch range {
        case .today: return (Calendar.current.startOfDay(for: now), .distantFuture, true)
        case .last24h: return (now.addingTimeInterval(-86400), .distantFuture, true)
        case .last7d: return (Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now))!, .distantFuture, true)
        case .last90d: return (Calendar.current.date(byAdding: .day, value: -89, to: Calendar.current.startOfDay(for: now))!, .distantFuture, true)
        case .custom: return (customFrom, customTo, customTo > now)
        }
    }

    func reload() {
        guard let dir = directory else { return }
        let (from, to) = (bounds.from, min(bounds.to, Date().addingTimeInterval(60)))
        loading = true
        Task.detached(priority: .userInitiated) {
            let read = LogFiles.read(directory: dir, from: from, to: to)
            await MainActor.run {
                self.entries = read
                self.lastSeen = read.last?.timestamp ?? .distantPast
                self.loading = false
                self.refilter()
            }
        }
    }

    /// New entries from this run (`recent` is newest first).
    func appendLive(from recent: [LogEntry]) {
        guard bounds.live, !loading else { return }
        let new = recent.prefix { $0.timestamp > lastSeen }.reversed()
        guard !new.isEmpty else { return }
        entries.append(contentsOf: new)
        lastSeen = entries.last?.timestamp ?? lastSeen
        refilter()
    }

    private func refilter() {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let (from, to) = (bounds.from, bounds.to)
        filtered = entries.reversed().filter { e in
            e.level >= minLevel && categories.contains(e.category) && e.timestamp >= from && e.timestamp <= to
                && (q.isEmpty || e.message.lowercased().contains(q) || e.event.lowercased().contains(q)
                    || e.fields.values.contains { $0.description.lowercased().contains(q) })
        }
    }
}

struct LogRow: View {
    let entry: LogEntry
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d  HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.time.string(from: entry.timestamp)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(entry.level.rawValue.uppercased()).font(.caption2.weight(.bold))
                .foregroundStyle(Self.levelColor(entry.level))
                .frame(width: 52, alignment: .leading)
            Text(entry.category.rawValue).font(.caption.weight(.semibold)).frame(width: 52, alignment: .leading)
            Text(entry.message).lineLimit(2)
        }
        .font(.callout)
    }

    static func levelColor(_ l: LogLevel) -> Color {
        switch l {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }

    /// Fires green, misses and errors red, warnings yellow, marks blue.
    static func highlight(_ e: LogEntry) -> Color {
        if e.event == "cue.missed" || e.level == .error { return .red.opacity(0.18) }
        if e.event == "cue.fired" || e.event == "cue.fired_manual" { return .green.opacity(0.2) }
        if e.event == "app.mark" { return .blue.opacity(0.15) }
        if e.level == .warning { return .yellow.opacity(0.2) }
        return .clear
    }
}

struct LogDetail: View {
    let entry: LogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.event).font(.callout.monospaced().weight(.semibold))
                    Spacer()
                    Text("campus: \(entry.campus.isEmpty ? "–" : entry.campus)  run: \(entry.run)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .controlSize(.small)
                }
                Text(entry.message).textSelection(.enabled)
                ForEach(entry.fields.keys.sorted(), id: \.self) { k in
                    Text("\(k): \(entry.fields[k]!.description)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var text: String {
        ([entry.timestamp.formatted(.iso8601), entry.event, entry.message]
            + entry.fields.keys.sorted().map { "\($0): \(entry.fields[$0]!)" }).joined(separator: "\n")
    }
}

struct MarkSheet: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a note to the log").font(.headline)
            Text("Use it to line up a reported problem with the log, e.g. “band said Song 2 felt late”.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Note", text: $text).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Add Mark", action: save).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        model.addMark(text)
        isPresented = false
    }
}

struct ExportSheet: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var days = 7
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Logs").font(.headline)
            Text("Makes one zip on the Desktop with the logs, the current settings and cue list, and system info (versions, Mac model, audio and MIDI devices). Send it to whoever is troubleshooting.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Include", selection: $days) {
                Text("Last 7 days").tag(7)
                Text("All 90 days").tag(90)
            }
            .pickerStyle(.radioGroup)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction).disabled(working)
                Button("Export") { run() }.keyboardShortcut(.defaultAction).disabled(working)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func run() {
        working = true
        error = nil
        Task {
            do {
                let url = try await model.exportLogs(days: days)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                isPresented = false
            } catch {
                self.error = "Export failed: \(error)"
            }
            working = false
        }
    }
}
