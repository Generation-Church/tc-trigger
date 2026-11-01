import Foundation
import Testing
@testable import TCTriggerKit

struct LoggingTests {
    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tctrigger-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func lines(_ url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }

    @Test func writesOneJSONObjectPerLineInDailyFile() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tz = TimeZone(identifier: "America/Phoenix")!
        let log = EventLog(directory: dir, timeZone: tz)
        log.campus = "Queen Creek"
        let date = Date(timeIntervalSince1970: 1_793_000_000.123) // 2026-10-26 local
        log.log(.info, .cue, "cue.fired", "Fired \"Song 2 – Way Maker\"\nline2",
                ["late_us": 42, "offset_ms": -120.5, "via": "exact", "ok": true, "none": nil], date: date)
        log.log(.debug, .ltc, "ltc.level", "dropped because verbose is off", date: date)
        log.verbose = true
        log.log(.debug, .ltc, "ltc.level", "kept", date: date)
        log.flush()

        let file = log.fileURL(forDay: "2026-10-26")
        #expect(file.lastPathComponent == "TC-Trigger_2026-10-26.jsonl")
        let rows = try Self.lines(file)
        #expect(rows.count == 2)
        let first = rows[0]
        #expect(first["ts"] as? String == "2026-10-26T00:33:20.123-07:00")
        #expect(first["lvl"] as? String == "info")
        #expect(first["cat"] as? String == "cue")
        #expect(first["evt"] as? String == "cue.fired")
        #expect(first["campus"] as? String == "Queen Creek")
        #expect(first["msg"] as? String == "Fired \"Song 2 – Way Maker\"\nline2")
        let f = first["f"] as! [String: Any]
        #expect(f["late_us"] as? Int == 42)
        #expect(f["offset_ms"] as? Double == -120.5)
        #expect(f["ok"] as? Bool == true)
        #expect(f["none"] is NSNull)
        #expect(rows[1]["lvl"] as? String == "debug")
        #expect(log.recent().count == 2)
    }

    @Test func newDayStartsNewFile() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tz = TimeZone(identifier: "America/Phoenix")!
        let log = EventLog(directory: dir, timeZone: tz)
        let day1 = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26 00:33 local
        log.log(.info, .app, "a", "one", date: day1.addingTimeInterval(-3600))
        log.log(.info, .app, "b", "two", date: day1)
        log.flush()
        #expect(try Self.lines(log.fileURL(forDay: "2026-10-25")).count == 1)
        #expect(try Self.lines(log.fileURL(forDay: "2026-10-26")).count == 1)
    }

    @Test func settingsChangesAreLoggedOldToNew() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = EventLog(directory: dir)
        let store = SettingsStore(fileURL: dir.appendingPathComponent("settings.json"), log: log)
        store.update { $0.campusName = "Queen Creek"; $0.audioChannel = 3 }
        store.update { $0.audioChannel = 3 } // no change → no log line
        log.flush()
        let entries = log.recent().filter { $0.event == "settings.changed" }
        #expect(entries.count == 2)
        let channel = entries.first { $0.fields["setting"] == "audioChannel" }
        #expect(channel?.fields["old"] == .int(1))
        #expect(channel?.fields["new"] == .int(3))

        let reloaded = SettingsStore(fileURL: dir.appendingPathComponent("settings.json"), log: nil)
        #expect(reloaded.settings.campusName == "Queen Creek")
        #expect(reloaded.settings.audioChannel == 3)
    }

    @Test func settingsToleratesMissingAndUnknownKeys() throws {
        let json = #"{"campusName":"Gilbert","someFutureSetting":true}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.campusName == "Gilbert")
        #expect(s.audioChannel == 1)
        #expect(s.audioDeviceUID == nil)
    }
}
