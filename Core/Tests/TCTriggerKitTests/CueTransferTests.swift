import Foundation
import Testing
@testable import TCTriggerKit

struct CueTransferTests {
    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cuetransfer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func exportThenImportRoundTrips() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = EventLog(directory: dir)
        let a = CueStore(fileURL: dir.appendingPathComponent("a.json"), log: log)
        a.replaceAll([
            Cue(name: "Song 3", timecode: Timecode(3, 0, 0, 0), note: 62, channel: 2, velocity: 100),
            Cue(name: "Song 2 – Way Maker", timecode: Timecode(2, 0, 0, 0), note: 61, enabled: false),
        ])
        let file = dir.appendingPathComponent("export.json")
        try a.exportFile(file)

        let b = CueStore(fileURL: dir.appendingPathComponent("b.json"), log: log)
        b.replaceAll([Cue(name: "Old", timecode: Timecode(1, 0, 0, 0))])
        try b.importFile(file)
        #expect(b.cues == a.cues)
        #expect(b.cues.map(\.name) == ["Song 2 – Way Maker", "Song 3"])

        log.flush()
        let imported = log.recent().first { $0.event == "cues.imported" }
        #expect(imported?.fields["count"] == 2)
        #expect(imported?.fields["replaced"] == 1)
        #expect(log.recent().contains { $0.event == "cues.exported" })
    }

    @Test func acceptsABareArrayAndFillsDefaults() throws {
        let json = #"[{"name":"Song 1","timecode":"01:00:00:00"},{"name":"Song 0","timecode":"00:30:00;10","note":5}]"#
        let cues = try CueTransfer.parse(Data(json.utf8))
        #expect(cues.map(\.name) == ["Song 0", "Song 1"])
        #expect(cues[1].note == 60 && cues[1].channel == 1 && cues[1].velocity == 127 && cues[1].enabled)
        #expect(cues[0].timecode == Timecode(0, 30, 0, 10))
    }

    @Test(arguments: [
        (#"{"foo": 1}"#, "no \"cues\" list"),
        (#"not json"#, "isn't valid JSON"),
        (#"{"cues":[{"name":"A","timecode":"01:00:00:00"},{"name":"Way Maker","timecode":"25:00:00:00"}]}"#,
         "Cue 2 (Way Maker): invalid timecode \"25:00:00:00\""),
        (#"{"cues":[{"name":"A","timecode":"01:00:00:00","channel":17}]}"#, "channel must be 1–16"),
        (#"{"cues":[{"name":"A"}]}"#, "Cue 1 (A) has no timecode"),
    ])
    func rejectsBadFilesWithAClearMessage(json: String, expected: String) {
        do {
            _ = try CueTransfer.parse(Data(json.utf8))
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".contains(expected), "got: \(error)")
        }
    }

    @Test func failedImportKeepsTheCurrentListAndLogs() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = EventLog(directory: dir)
        let store = CueStore(fileURL: dir.appendingPathComponent("c.json"), log: log)
        let existing = [Cue(name: "Keep", timecode: Timecode(1, 0, 0, 0))]
        store.replaceAll(existing)
        let bad = dir.appendingPathComponent("bad.json")
        try Data(#"{"cues":[{"timecode":"99"}]}"#.utf8).write(to: bad)
        #expect(throws: CueImportError.self) { try store.importFile(bad) }
        #expect(store.cues == existing)
        log.flush()
        #expect(log.recent().contains { $0.event == "cues.import_failed" })
    }

    @Test func duplicateIDsInAFileAreMadeUnique() throws {
        let id = UUID().uuidString
        let json = #"[{"id":"\#(id)","name":"A","timecode":"01:00:00:00"},{"id":"\#(id)","name":"B","timecode":"02:00:00:00"}]"#
        let cues = try CueTransfer.parse(Data(json.utf8))
        #expect(Set(cues.map(\.id)).count == 2)
    }

    @Test func suggestedFileName() {
        let date = Date(timeIntervalSince1970: 1_793_570_400) // 2026-11-01
        #expect(CueTransfer.suggestedFileName(campus: "Queen Creek", date: date).hasPrefix("TC-Trigger-Cues_QueenCreek_2026-1"))
        #expect(CueTransfer.suggestedFileName(campus: "", date: date).hasPrefix("TC-Trigger-Cues_Campus_"))
    }

    @Test func warnings() {
        let a = Cue(name: "A", timecode: Timecode(1, 0, 0, 0), note: 60)
        let b = Cue(name: "B", timecode: Timecode(1, 0, 0, 0), note: 61)
        let c = Cue(name: "C", timecode: Timecode(2, 0, 0, 27), note: 60)
        let d = Cue(name: " ", timecode: Timecode(3, 1, 0, 0), note: 70)
        var off = Cue(name: "Off", timecode: Timecode(1, 0, 0, 0), note: 60)
        off.enabled = false
        let w = CueWarnings.check([a, b, c, d, off], rate: .fps25)
        #expect(w[a.id]?.contains { $0.contains("same timecode") } == true)
        #expect(w[a.id]?.contains { $0.contains("Same note and channel as C") } == true)
        #expect(w[c.id]?.contains { $0.contains("doesn't exist at 25 fps") } == true)
        #expect(w[d.id]?.contains { $0.contains("No name") } == true)
        #expect(w[off.id] == nil)
        let df = CueWarnings.check([d], rate: .fps2997DF)
        #expect(df[d.id]?.contains { $0.contains("skipped in 29.97 drop-frame") } == true)
    }
}
