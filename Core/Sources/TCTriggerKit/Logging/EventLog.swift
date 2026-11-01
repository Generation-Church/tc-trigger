import Foundation
import os

/// The troubleshooting log: one JSON object per line, one file per local day, written from a
/// background queue so it can never delay audio or MIDI. Info and above are mirrored to
/// Apple's unified log (Console.app, subsystem "church.generation.tctrigger").
public final class EventLog: @unchecked Sendable {
    public static let filePrefix = "TC-Trigger_"
    public static let fileExtension = "jsonl"

    public let directory: URL
    /// Identifies this launch of the app in every line.
    public let run: String

    private let queue = DispatchQueue(label: "church.generation.tctrigger.log", qos: .utility)
    private let osLog = Logger(subsystem: "church.generation.tctrigger", category: "events")
    private let stateLock = NSLock()
    private var _campus = ""
    private var _verbose = false
    private var observers: [UUID: (LogEntry) -> Void] = [:]

    // Touched only on `queue`.
    private var handle: FileHandle?
    private var handleDay: String?
    private let lineFormatter: DateFormatter
    private let dayFormatter: DateFormatter

    /// Most recent entries, newest last (for the live view).
    private var recentBuffer: [LogEntry] = []
    public let recentCapacity = 1000

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TC Trigger", isDirectory: true)
    }

    public init(directory: URL = EventLog.defaultDirectory, timeZone: TimeZone = .current) {
        self.directory = directory
        self.run = String(UUID().uuidString.prefix(8)).lowercased()
        lineFormatter = DateFormatter()
        lineFormatter.locale = Locale(identifier: "en_US_POSIX")
        lineFormatter.timeZone = timeZone
        lineFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSxxx"
        dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var campus: String {
        get { stateLock.withLock { _campus } }
        set { stateLock.withLock { _campus = newValue } }
    }

    /// When false, `.debug` entries are discarded.
    public var verbose: Bool {
        get { stateLock.withLock { _verbose } }
        set { stateLock.withLock { _verbose = newValue } }
    }

    public func fileURL(forDay day: String) -> URL {
        directory.appendingPathComponent("\(Self.filePrefix)\(day).\(Self.fileExtension)")
    }

    /// Record an event. Safe to call from any thread except the real-time audio thread.
    public func log(_ level: LogLevel, _ category: LogCategory, _ event: String,
                    _ message: String, _ fields: LogFields = [:], date: Date = Date()) {
        let (campus, verbose) = stateLock.withLock { (_campus, _verbose) }
        if level == .debug && !verbose { return }
        let entry = LogEntry(timestamp: date, level: level, category: category, event: event,
                             message: message, fields: fields, campus: campus, run: run)
        queue.async { self.write(entry) }
    }

    public func info(_ c: LogCategory, _ e: String, _ m: String, _ f: LogFields = [:]) { log(.info, c, e, m, f) }
    public func debug(_ c: LogCategory, _ e: String, _ m: String, _ f: LogFields = [:]) { log(.debug, c, e, m, f) }
    public func warning(_ c: LogCategory, _ e: String, _ m: String, _ f: LogFields = [:]) { log(.warning, c, e, m, f) }
    public func error(_ c: LogCategory, _ e: String, _ m: String, _ f: LogFields = [:]) { log(.error, c, e, m, f) }

    /// Wait until everything logged so far is on disk.
    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    /// Entries from this launch, oldest first.
    public func recent() -> [LogEntry] { queue.sync { recentBuffer } }

    /// Be told about every new entry (called on the log queue).
    @discardableResult
    public func addObserver(_ block: @escaping (LogEntry) -> Void) -> UUID {
        let id = UUID()
        stateLock.withLock { observers[id] = block }
        return id
    }

    public func removeObserver(_ id: UUID) {
        stateLock.withLock { _ = observers.removeValue(forKey: id) }
    }

    // MARK: Writing (log queue only)

    private func write(_ entry: LogEntry) {
        let line = encode(entry) + "\n"
        let day = dayFormatter.string(from: entry.timestamp)
        if day != handleDay {
            try? handle?.close()
            handle = openHandle(day: day)
            handleDay = day
        }
        if let data = line.data(using: .utf8) {
            do { try handle?.write(contentsOf: data) } catch {
                osLog.error("Log write failed: \(error.localizedDescription, privacy: .public)")
                handle = nil
                handleDay = nil
            }
        }

        if entry.level >= .info {
            let text = "[\(entry.category.rawValue)] \(entry.event): \(entry.message)"
            switch entry.level {
            case .error: osLog.error("\(text, privacy: .public)")
            case .warning: osLog.warning("\(text, privacy: .public)")
            default: osLog.notice("\(text, privacy: .public)")
            }
        }

        recentBuffer.append(entry)
        if recentBuffer.count > recentCapacity { recentBuffer.removeFirst(recentBuffer.count - recentCapacity) }
        let obs = stateLock.withLock { Array(observers.values) }
        for o in obs { o(entry) }
    }

    private func openHandle(day: String) -> FileHandle? {
        let url = fileURL(forDay: day)
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? h.seekToEnd()
        return h
    }

    /// Fixed key order so files are easy to read by eye: ts, lvl, cat, evt, campus, run, msg, f.
    func encode(_ e: LogEntry) -> String {
        var s = "{\"ts\":\(JSONText.quote(lineFormatter.string(from: e.timestamp)))"
        s += ",\"lvl\":\"\(e.level.rawValue)\",\"cat\":\"\(e.category.rawValue)\""
        s += ",\"evt\":\(JSONText.quote(e.event)),\"campus\":\(JSONText.quote(e.campus))"
        s += ",\"run\":\(JSONText.quote(e.run)),\"msg\":\(JSONText.quote(e.message))"
        if !e.fields.isEmpty {
            let body = e.fields.keys.sorted()
                .map { "\(JSONText.quote($0)):\(e.fields[$0]!.json)" }
                .joined(separator: ",")
            s += ",\"f\":{\(body)}"
        }
        return s + "}"
    }
}
