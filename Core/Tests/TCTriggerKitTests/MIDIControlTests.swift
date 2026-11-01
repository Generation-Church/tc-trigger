import CoreMIDI
import Foundation
import Testing
@testable import TCTriggerKit

struct MIDIControlTests {
    static func noteOn(_ n: UInt8, ch: UInt8 = 0, vel: UInt8 = 127) -> MIDIMessage { MIDIMessage(0x90 | ch, n, vel) }
    static func noteOff(_ n: UInt8, ch: UInt8 = 0) -> MIDIMessage { MIDIMessage(0x80 | ch, n, 0) }
    static func cc(_ n: UInt8, _ v: UInt8, ch: UInt8 = 0) -> MIDIMessage { MIDIMessage(0xB0 | ch, n, v) }

    /// Feed (message, time) pairs; return the actions.
    static func run(_ mapping: [ControlAction: MIDITrigger], _ input: [(MIDIMessage, Double)]) -> [ControlAction] {
        let i = ControlInterpreter(mappings: mapping)
        return input.flatMap { i.handle($0.0, at: $0.1) }
    }

    @Test func momentaryNotePressAndReleaseTriggersOnce() {
        let t = MIDITrigger(kind: .note, channel: 1, number: 36, style: .momentary)
        let a = Self.run([.toggleArm: t], [(Self.noteOn(36), 0), (Self.noteOff(36), 0.1),
                                           (Self.noteOn(36), 1.0), (Self.noteOn(36, vel: 0), 1.1)])
        #expect(a == [.toggleArm, .toggleArm])
    }

    @Test func singleMessageNoteTriggersEachPressButNotBounces() {
        let t = MIDITrigger(kind: .note, channel: 1, number: 36, style: .single)
        let a = Self.run([.fireNext: t], [(Self.noteOn(36), 0), (Self.noteOn(36), 0.05), // bounce
                                          (Self.noteOn(36), 0.6)])
        #expect(a == [.fireNext, .fireNext])
    }

    @Test func momentaryCCFiresOnRisingEdgeOnly() {
        let t = MIDITrigger(kind: .cc, channel: 1, number: 20, style: .momentary)
        let a = Self.run([.arm: t], [(Self.cc(20, 127), 0), (Self.cc(20, 127), 0.02), (Self.cc(20, 0), 0.2),
                                     (Self.cc(20, 127), 1.0), (Self.cc(20, 0), 1.2)])
        #expect(a == [.arm, .arm])
    }

    @Test func singleMessageCCFiresEveryPress() {
        // A controller that only ever sends 127, one message per press.
        let t = MIDITrigger(kind: .cc, channel: 1, number: 20, style: .single)
        let a = Self.run([.panic: t], [(Self.cc(20, 127), 0), (Self.cc(20, 127), 0.5), (Self.cc(20, 127), 1.0)])
        #expect(a == [.panic, .panic, .panic])
    }

    @Test func togglingCCFiresOnBothValues() {
        // A toggle button sends 127 then 0 on alternate presses: each press is one action.
        let t = MIDITrigger(kind: .cc, channel: 1, number: 20, style: .single)
        let a = Self.run([.toggleArm: t], [(Self.cc(20, 127), 0), (Self.cc(20, 0), 0.8), (Self.cc(20, 127), 1.6)])
        #expect(a == [.toggleArm, .toggleArm, .toggleArm])
    }

    @Test func otherChannelsAndNumbersAreIgnored() {
        let t = MIDITrigger(kind: .note, channel: 10, number: 36, style: .momentary)
        let a = Self.run([.arm: t], [(Self.noteOn(36, ch: 0), 0), (Self.noteOn(37, ch: 9), 1), (Self.cc(36, 127, ch: 9), 2),
                                     (Self.noteOn(36, ch: 9), 3)])
        #expect(a == [.arm])
    }

    @Test func learnDetectsMomentaryNote() {
        var s = LearnSession()
        #expect(s.feed(Self.cc(7, 0), at: 0) == MIDITrigger?.none) // CC learnable too; this starts the session
        var s2 = LearnSession()
        #expect(s2.feed(Self.noteOn(36, ch: 9), at: 0) == nil)
        #expect(s2.feed(Self.noteOff(36, ch: 9), at: 0.15) == MIDITrigger(kind: .note, channel: 10, number: 36, style: .momentary))
        _ = s
    }

    @Test func learnDetectsSingleMessageWhenNoReleaseArrives() {
        var s = LearnSession()
        #expect(s.feed(Self.cc(20, 127), at: 0) == nil)
        #expect(s.finish(at: 0.3) == nil) // still waiting
        #expect(s.finish(at: 0.7) == MIDITrigger(kind: .cc, channel: 1, number: 20, style: .single))
    }

    @Test func learnDetectsMomentaryCC() {
        var s = LearnSession()
        _ = s.feed(Self.cc(20, 127), at: 0)
        #expect(s.feed(Self.cc(21, 0), at: 0.1) == nil) // different control is ignored
        #expect(s.feed(Self.cc(20, 0), at: 0.2) == MIDITrigger(kind: .cc, channel: 1, number: 20, style: .momentary))
    }

    @Test func learnIgnoresNoteOffsAndOtherMessages() {
        var s = LearnSession()
        #expect(s.feed(Self.noteOff(36), at: 0) == nil)
        #expect(s.feed(MIDIMessage(0xE0, 0, 64), at: 0) == nil) // pitch bend
        #expect(s.first == nil)
    }

    @Test func feedbackMessages() {
        let n = MIDITrigger(kind: .note, channel: 2, number: 40, style: .momentary)
        #expect(MIDIMessages.feedback(n, armed: true) == MIDIMessage(0x91, 40, 127))
        #expect(MIDIMessages.feedback(n, armed: false) == MIDIMessage(0x91, 40, 0))
        let c = MIDITrigger(kind: .cc, channel: 16, number: 64, style: .single)
        #expect(MIDIMessages.feedback(c, armed: true) == MIDIMessage(0xBF, 64, 127))
    }

    @Test func panicCoversCueNotesAndAllChannels() {
        let cues = [Cue(name: "A", timecode: Timecode(1, 0, 0, 0), note: 60, channel: 1),
                    Cue(name: "B", timecode: Timecode(2, 0, 0, 0), note: 60, channel: 1),
                    Cue(name: "C", timecode: Timecode(3, 0, 0, 0), note: 62, channel: 3)]
        let m = MIDIMessages.panic(cues: cues)
        #expect(m.prefix(2) == [MIDIMessage(0x80, 60, 0), MIDIMessage(0x82, 62, 0)])
        #expect(m.count == 2 + 16)
        #expect(m.suffix(16).allSatisfy { $0.kind == 0xB0 && $0.data1 == 123 })
    }

    @Test func fireNextOrder() {
        var b = Cue(name: "B", timecode: Timecode(2, 0, 0, 0))
        let a = Cue(name: "A", timecode: Timecode(1, 0, 0, 0))
        let c = Cue(name: "C", timecode: Timecode(3, 0, 0, 0))
        b.enabled = false
        let cues = [c, b, a]
        #expect(nextCueToFire(after: nil, in: cues)?.name == "A")
        #expect(nextCueToFire(after: a.id, in: cues)?.name == "C") // skips disabled B
        #expect(nextCueToFire(after: c.id, in: cues) == nil)
    }

    @Test func mappingChangesAreLoggedOldToNew() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("map-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = EventLog(directory: dir)
        let store = SettingsStore(fileURL: dir.appendingPathComponent("s.json"), log: log)
        store.update { $0.controlMappings["arm"] = MIDITrigger(kind: .note, channel: 10, number: 36, style: .momentary) }
        log.flush()
        let e = log.recent().first { $0.fields["setting"] == "controlMappings" }
        #expect(e != nil)
        #expect(e?.fields["new"]?.description.contains("\"number\":36") == true)
        let reloaded = SettingsStore(fileURL: dir.appendingPathComponent("s.json"), log: nil)
        #expect(reloaded.settings.mappings[.arm]?.number == 36)
    }
}

struct ManualFireTests {
    @Test func fireNextSendsEvenWhenDisarmed() async throws {
        let sink = RecordingMIDISink()
        let s = FireScheduler(sink: sink)
        defer { s.shutdown() }
        s.armed = false
        s.manualFire(Cue(name: "A", timecode: Timecode(1, 0, 0, 0), note: 60))
        try await Task.sleep(for: .milliseconds(200))
        #expect(sink.messages.map(\.status) == [0x90, 0x80])
    }
}

/// End-to-end through CoreMIDI: the real virtual source, received by a real input port.
struct VirtualSourceTests {
    final class Received: @unchecked Sendable {
        let lock = NSLock()
        var words: [UInt32] = []
    }

    @Test func panicMessagesAllArrive() async throws {
        let name = "TC Trigger Test \(UUID().uuidString.prefix(6))"
        let source = try VirtualMIDISource(name: name, uniqueID: nil)
        var client = MIDIClientRef()
        MIDIClientCreateWithBlock("panic test" as CFString, &client) { _ in }
        defer { MIDIClientDispose(client) }
        var port = MIDIPortRef()
        let rx = Received()
        MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &port) { list, _ in
            for p in list.unsafeSequence() {
                for w in MIDIEventPacket.WordCollection(p) { rx.lock.withLock { rx.words.append(w) } }
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        let ref = (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }.first { s in
            var n: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(s, kMIDIPropertyName, &n)
            return (n?.takeRetainedValue() as String?) == name
        }
        #expect(ref != nil)
        MIDIPortConnectSource(port, ref!, nil)
        try await Task.sleep(for: .milliseconds(200))

        let scheduler = FireScheduler(sink: source)
        defer { scheduler.shutdown() }
        let msgs = MIDIMessages.panic(cues: [Cue(name: "A", timecode: Timecode(1, 0, 0, 0), note: 60)])
        scheduler.sendNow(msgs.map { ($0.status, $0.data1, $0.data2) })
        try await Task.sleep(for: .milliseconds(300))
        let got = rx.lock.withLock { rx.words }
        #expect(got.count == msgs.count, "received \(got.map { String(format: "%08X", $0) })")
    }
}
