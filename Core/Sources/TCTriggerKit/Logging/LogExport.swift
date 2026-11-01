import CoreMIDI
import Foundation

/// Builds the one-click troubleshooting zip, e.g. `TC-Trigger_QueenCreek_2026-11-01.zip`:
///
///     TC-Trigger_QueenCreek_2026-11-01/
///       README.txt
///       logs/TC-Trigger_2026-10-26.jsonl …
///       settings.json
///       cues.json
///       system-info.json
public enum LogExport {
    public struct Options {
        public var days: Int = 7
        public var campus: String
        public var logDirectory: URL
        public var settingsFile: URL?
        public var cuesFile: URL?
        public var destinationFolder: URL
        public var now = Date()
        public var timeZone = TimeZone.current
        /// Extra system facts (devices etc.). Defaults to `SystemInfo.report()`.
        public var systemInfo: [String: Any]?

        public init(campus: String, logDirectory: URL, settingsFile: URL?, cuesFile: URL?, destinationFolder: URL) {
            self.campus = campus
            self.logDirectory = logDirectory
            self.settingsFile = settingsFile
            self.cuesFile = cuesFile
            self.destinationFolder = destinationFolder
        }
    }

    public struct ExportError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func baseName(campus: String, now: Date, timeZone: TimeZone = .current) -> String {
        let slug = campus.filter { $0.isLetter || $0.isNumber }
        return "TC-Trigger_\(slug.isEmpty ? "Campus" : slug)_\(LogFiles.dayFormatter(timeZone).string(from: now))"
    }

    /// Creates the zip and returns its URL. Never overwrites: adds "-2", "-3" … if needed.
    public static func export(_ o: Options) throws -> URL {
        let fm = FileManager.default
        let base = baseName(campus: o.campus, now: o.now, timeZone: o.timeZone)
        let work = fm.temporaryDirectory.appendingPathComponent("tctrigger-export-\(UUID().uuidString)")
        let folder = work.appendingPathComponent(base)
        let logs = folder.appendingPathComponent("logs")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = o.timeZone
        let from = cal.date(byAdding: .day, value: -(o.days - 1), to: cal.startOfDay(for: o.now))!
        let files = LogFiles.files(in: o.logDirectory, from: from, to: o.now, timeZone: o.timeZone)
        for f in files {
            try fm.copyItem(at: f.url, to: logs.appendingPathComponent(f.url.lastPathComponent))
        }
        if let s = o.settingsFile, fm.fileExists(atPath: s.path) {
            try fm.copyItem(at: s, to: folder.appendingPathComponent("settings.json"))
        }
        if let c = o.cuesFile, fm.fileExists(atPath: c.path) {
            try fm.copyItem(at: c, to: folder.appendingPathComponent("cues.json"))
        }
        var info = o.systemInfo ?? SystemInfo.report()
        info["campus"] = o.campus
        info["export_days"] = o.days
        info["exported_at"] = ISO8601DateFormatter().string(from: o.now)
        info["log_files"] = files.map(\.url.lastPathComponent)
        let infoData = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        try infoData.write(to: folder.appendingPathComponent("system-info.json"))
        let readme = """
        TC Trigger troubleshooting export
        Campus: \(o.campus.isEmpty ? "(not set)" : o.campus)
        Covers the last \(o.days) day(s): \(files.count) log file(s).

        logs/          one JSON object per line; fields: ts, lvl, cat, evt, campus, run, msg, f
        settings.json  TC Trigger settings at export time
        cues.json      the cue list at export time
        system-info.json  app/macOS version, Mac model, audio and MIDI devices present
        """
        try readme.write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        try fm.createDirectory(at: o.destinationFolder, withIntermediateDirectories: true)
        var zip = o.destinationFolder.appendingPathComponent(base + ".zip")
        var n = 2
        while fm.fileExists(atPath: zip.path) {
            zip = o.destinationFolder.appendingPathComponent("\(base)-\(n).zip")
            n += 1
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", folder.path, zip.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ExportError(description: "Creating the zip failed: \(msg)")
        }
        return zip
    }
}

extension SystemInfo {
    /// Everything useful about this Mac for a troubleshooting export.
    public static func report() -> [String: Any] {
        let audio = AudioDevices.inputDevices().map {
            ["name": $0.name, "uid": $0.uid, "input_channels": $0.inputChannels, "sample_rate": $0.nominalSampleRate] as [String: Any]
        }
        func names(_ count: Int, _ get: (Int) -> MIDIEndpointRef) -> [String] {
            (0..<count).compactMap { i in
                var n: Unmanaged<CFString>?
                MIDIObjectGetStringProperty(get(i), kMIDIPropertyDisplayName, &n)
                return n?.takeRetainedValue() as String?
            }
        }
        return [
            "app_version": appVersion,
            "macos_version": macOSVersion,
            "mac_model": macModel,
            "host_name": hostName,
            "time_zone": TimeZone.current.identifier,
            "uptime_hours": (ProcessInfo.processInfo.systemUptime / 3600 * 10).rounded() / 10,
            "audio_input_devices": audio,
            "midi_sources": names(MIDIGetNumberOfSources()) { MIDIGetSource($0) },
            "midi_destinations": names(MIDIGetNumberOfDestinations()) { MIDIGetDestination($0) },
        ]
    }
}
