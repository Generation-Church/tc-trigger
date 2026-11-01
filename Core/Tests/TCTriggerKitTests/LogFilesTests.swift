import Foundation
import Testing
@testable import TCTriggerKit

struct LogFilesTests {
    static let tz = TimeZone(identifier: "America/Phoenix")!
    /// 2026-11-01 12:00 local.
    static let now = Date(timeIntervalSince1970: 1_793_559_600)

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("logfiles-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func day(_ offset: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return LogFiles.dayFormatter(tz).string(from: cal.date(byAdding: .day, value: offset, to: now)!)
    }

    static func makeFile(_ dir: URL, dayOffset: Int, bytes: Int = 100) {
        let url = dir.appendingPathComponent("TC-Trigger_\(day(dayOffset)).jsonl")
        try? Data(repeating: 0x41, count: bytes).write(to: url)
    }

    @Test func deletesFilesOlderThan90Days() {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for d in [0, -1, -89, -90, -91, -200] { Self.makeFile(dir, dayOffset: d) }
        try? Data("not a log".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let deleted = LogFiles.prune(directory: dir, now: Self.now, timeZone: Self.tz)
        #expect(Set(deleted.map(\.day)) == [Self.day(-91), Self.day(-200)])
        #expect(LogFiles.list(in: dir).map(\.day) == [Self.day(-90), Self.day(-89), Self.day(-1), Self.day(0)])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.txt").path))
    }

    @Test func sizeCapDeletesOldestFirstButKeepsToday() {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for d in [-3, -2, -1] { Self.makeFile(dir, dayOffset: d, bytes: 400) }
        Self.makeFile(dir, dayOffset: 0, bytes: 900) // today alone is over the cap
        let deleted = LogFiles.prune(directory: dir, now: Self.now, timeZone: Self.tz, maxTotalBytes: 1000)
        #expect(deleted.map(\.day) == [Self.day(-3), Self.day(-2), Self.day(-1)])
        #expect(LogFiles.list(in: dir).map(\.day) == [Self.day(0)])
    }

    @Test func sizeCapStopsOnceUnderTheLimit() {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for d in [-3, -2, -1, 0] { Self.makeFile(dir, dayOffset: d, bytes: 300) }
        let deleted = LogFiles.prune(directory: dir, now: Self.now, timeZone: Self.tz, maxTotalBytes: 1000)
        #expect(deleted.map(\.day) == [Self.day(-3)])
    }

    @Test func readsBackWhatEventLogWroteWithinARange() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = EventLog(directory: dir, timeZone: Self.tz)
        log.campus = "Queen Creek"
        for (i, offset) in [-3.0, -1.0, 0.0].enumerated() {
            log.log(.info, .cue, "cue.fired", "fire \(i)", ["n": .int(i), "late": .double(0.5)],
                    date: Self.now.addingTimeInterval(offset * 86400))
        }
        log.log(.warning, .audio, "audio.disconnected", "gone", date: Self.now)
        log.flush()
        let all = LogFiles.read(directory: dir, from: Self.now.addingTimeInterval(-10 * 86400), to: Self.now)
        #expect(all.map(\.message) == ["fire 0", "fire 1", "fire 2", "gone"])
        #expect(all[0].campus == "Queen Creek")
        #expect(all[0].fields["n"] == .int(0))
        #expect(all[3].level == .warning && all[3].category == .audio)
        #expect(abs(all[2].timestamp.timeIntervalSince(Self.now)) < 0.002)
        let recent = LogFiles.read(directory: dir, from: Self.now.addingTimeInterval(-2 * 86400), to: Self.now)
        #expect(recent.map(\.message) == ["fire 1", "fire 2", "gone"])
    }
}

struct LogExportTests {
    @Test func zipContainsLogsSettingsCuesAndSystemInfo() throws {
        let fm = FileManager.default
        let root = LogFilesTests.tempDir()
        defer { try? fm.removeItem(at: root) }
        let logDir = root.appendingPathComponent("logs")
        try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        for d in [-10, -6, -1, 0] { LogFilesTests.makeFile(logDir, dayOffset: d) }
        let settings = root.appendingPathComponent("settings.json")
        try Data(#"{"campusName":"Queen Creek"}"#.utf8).write(to: settings)
        let cues = root.appendingPathComponent("cues.json")
        try CueStore.encode([Cue(name: "Song 2", timecode: Timecode(1, 0, 0, 0))]).write(to: cues)

        var o = LogExport.Options(campus: "Queen Creek", logDirectory: logDir, settingsFile: settings, cuesFile: cues,
                                  destinationFolder: root.appendingPathComponent("Desktop"))
        o.now = LogFilesTests.now
        o.timeZone = LogFilesTests.tz
        o.systemInfo = ["app_version": "test", "audio_input_devices": [["name": "MOTU"]]]
        let zip = try LogExport.export(o)
        #expect(zip.lastPathComponent == "TC-Trigger_QueenCreek_2026-11-01.zip")

        // A second export the same day doesn't overwrite the first.
        let zip2 = try LogExport.export(o)
        #expect(zip2.lastPathComponent == "TC-Trigger_QueenCreek_2026-11-01-2.zip")

        let out = root.appendingPathComponent("unzipped")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        try p.run()
        p.waitUntilExit()
        let folder = out.appendingPathComponent("TC-Trigger_QueenCreek_2026-11-01")
        let logs = try fm.contentsOfDirectory(atPath: folder.appendingPathComponent("logs").path).sorted()
        // Default 7 days: today back to 6 days ago.
        #expect(logs == [-6, -1, 0].map { "TC-Trigger_\(LogFilesTests.day($0)).jsonl" })
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("settings.json").path))
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("README.txt").path))
        let exportedCues = try CueTransfer.parse(Data(contentsOf: folder.appendingPathComponent("cues.json")))
        #expect(exportedCues.map(\.name) == ["Song 2"])
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("system-info.json"))) as! [String: Any]
        #expect(info["campus"] as? String == "Queen Creek")
        #expect(info["app_version"] as? String == "test")
        #expect((info["log_files"] as? [String])?.count == 3)
    }

    @Test func allNinetyDaysOption() throws {
        let root = LogFilesTests.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let logDir = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        for d in [-89, -30, -10, 0] { LogFilesTests.makeFile(logDir, dayOffset: d) }
        var o = LogExport.Options(campus: "", logDirectory: logDir, settingsFile: nil, cuesFile: nil,
                                  destinationFolder: root.appendingPathComponent("out"))
        o.now = LogFilesTests.now
        o.timeZone = LogFilesTests.tz
        o.days = 90
        o.systemInfo = [:]
        let zip = try LogExport.export(o)
        #expect(zip.lastPathComponent.hasPrefix("TC-Trigger_Campus_"))
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        list.arguments = ["-1", zip.path]
        let pipe = Pipe()
        list.standardOutput = pipe
        try list.run()
        list.waitUntilExit()
        let names = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
        #expect(names.components(separatedBy: "\n").filter { $0.hasSuffix(".jsonl") }.count == 4)
    }

    @Test func realSystemReportHasDevices() {
        let r = SystemInfo.report()
        #expect(r["mac_model"] as? String != nil)
        #expect(r["audio_input_devices"] is [[String: Any]])
        #expect(r["midi_sources"] is [String])
    }
}
