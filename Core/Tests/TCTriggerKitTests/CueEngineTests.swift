import Foundation
import Testing
@testable import TCTriggerKit

/// Drives TriggerCore like the live engine does: frames arrive one frame period (+5 ms of
/// audio latency) after they start, the engine ticks every 2 ms, and a fake scheduler "fires"
/// each schedule when its time comes.
final class Sim {
    struct Fire: Equatable {
        let cue: String
        let at: UInt64
        let via: FireVia
        let lateFrames: Int
    }

    static let base: UInt64 = 100_000_000_000
    let core: TriggerCore
    let rate: FrameRate
    var now: UInt64 = Sim.base
    var fires: [Fire] = []
    var misses: [(cue: String, reason: String)] = []
    var cancels: [(cue: String, reason: String)] = []
    var events: [LTCEvent] = []
    private var pending: [UUID: (Cue, UInt64, FireVia, Int)] = [:]

    init(rate: FrameRate = .fps25, cues: [Cue], offsetMs: Int = 0, catchWindow: Int = 3) {
        self.rate = rate
        var cfg = CueEngine.Config()
        cfg.offset = Double(offsetMs) / 1000
        cfg.catchWindow = catchWindow
        core = TriggerCore(cueConfig: cfg)
        _ = core.cues.setCues(cues)
    }

    /// Host time at which frame `index` starts, for a run where `firstIndex` starts at `startSeconds`.
    func time(of index: Int, firstIndex: Int, startSeconds: Double) -> UInt64 {
        HostClock.adding(startSeconds + Double(index - firstIndex) / rate.exact, to: Sim.base)
    }

    /// Play frames `from...to` (skipping `skip`), with frame `from` starting at `startSeconds`.
    func play(from: Timecode, to: Timecode, startSeconds: Double, skip: Set<Timecode> = []) {
        let a = from.frameIndex(at: rate), b = to.frameIndex(at: rate)
        for i in a...b {
            let tc = Timecode(frameIndex: i, rate: rate)
            guard !skip.contains(tc) else { continue }
            let start = time(of: i, firstIndex: a, startSeconds: startSeconds)
            let arrival = HostClock.adding(1 / rate.exact + 0.005, to: start)
            advance(to: arrival)
            let out = core.ingest(DecodedFrame(timecode: tc, dropFrameFlag: rate.isDropFrame, hostTime: start), now: now)
            record(out)
        }
    }

    /// Let time pass with no LTC (ticking every 2 ms).
    func silence(_ seconds: Double) { advance(to: HostClock.adding(seconds, to: now)) }

    private func advance(to t: UInt64) {
        while now < t {
            now = min(t, HostClock.adding(0.002, to: now))
            fireDue()
            record(core.tick(now: now))
        }
        fireDue()
    }

    private func fireDue() {
        for (id, p) in pending where p.1 <= now {
            pending[id] = nil
            fires.append(Fire(cue: p.0.name, at: p.1, via: p.2, lateFrames: p.3))
            core.cues.markFired(id)
        }
    }

    private func record(_ out: TriggerCore.Output) {
        events += out.ltcEvents
        for a in out.actions {
            switch a {
            case let .schedule(cue, at, _, via, late, _): pending[cue.id] = (cue, at, via, late)
            case let .cancel(cue, reason):
                if pending.removeValue(forKey: cue.id) != nil { cancels.append((cue.name, reason)) }
            case let .missed(cue, reason, _): misses.append((cue.name, reason))
            case .timingCheck: break
            }
        }
    }

    /// Seconds between a fire and the true start of a frame in a run.
    func error(of fire: Fire, versus tc: Timecode, firstIndex: Timecode, startSeconds: Double, offsetMs: Int = 0) -> Double {
        let truth = HostClock.adding(Double(offsetMs) / 1000,
                                     to: time(of: tc.frameIndex(at: rate), firstIndex: firstIndex.frameIndex(at: rate),
                                              startSeconds: startSeconds))
        return abs(HostClock.seconds(from: truth, to: fire.at))
    }
}

struct CueEngineTests {
    static let cueTC = Timecode(1, 0, 0, 0)
    static let song = Cue(name: "Song 2 – Way Maker", timecode: cueTC, note: 60)

    @Test(arguments: FrameRate.allCases)
    func exactHitFiresOnceOnTheCueFrame(rate: FrameRate) {
        let sim = Sim(rate: rate, cues: [Self.song])
        let start = Timecode(frameIndex: Self.cueTC.frameIndex(at: rate) - Int(3 * rate.exact), rate: rate)
        sim.play(from: start, to: Timecode(1, 0, 5, 0), startSeconds: 0)
        sim.silence(2)
        #expect(sim.fires.count == 1, "fires \(sim.fires.map { "\($0.via) late \($0.lateFrames)" }) misses \(sim.misses) cancels \(sim.cancels)")
        #expect(sim.fires.first?.via == .exact)
        #expect(sim.misses.isEmpty)
        if let f = sim.fires.first {
            let err = sim.error(of: f, versus: Self.cueTC, firstIndex: start, startSeconds: 0)
            #expect(err < 0.0001, "fired \(err * 1000) ms from the cue frame")
        }
    }

    @Test(arguments: [-1000, -400, -120, 120, 500, 1000])
    func offsetShiftsTheFireTime(offsetMs: Int) {
        let sim = Sim(cues: [Self.song], offsetMs: offsetMs)
        let start = Timecode(0, 59, 57, 0)
        sim.play(from: start, to: Timecode(1, 0, 3, 0), startSeconds: 0)
        #expect(sim.fires.count == 1)
        if let f = sim.fires.first {
            #expect(f.via == .exact)
            let err = sim.error(of: f, versus: Self.cueTC, firstIndex: start, startSeconds: 0, offsetMs: offsetMs)
            #expect(err < 0.0001, "fired \(err * 1000) ms off target")
        }
    }

    @Test func glitchOnTheCueFrameStillFiresOnTime() {
        let sim = Sim(cues: [Self.song])
        let start = Timecode(0, 59, 57, 0)
        sim.play(from: start, to: Timecode(1, 0, 3, 0), startSeconds: 0,
                 skip: [Timecode(1, 0, 0, 0), Timecode(1, 0, 0, 1)])
        #expect(sim.fires.count == 1)
        #expect(sim.fires.first?.via == .exact)
        #expect(sim.cancels.isEmpty)
    }

    @Test func dropoutBeforeCueIsCaughtInsideTheWindow() {
        // LTC drops out from 10 frames before the cue and returns 2 frames after it.
        let sim = Sim(cues: [Self.song])
        let start = Timecode(0, 59, 57, 0)
        let skip = Set((Timecode(0, 59, 59, 15).frameIndex(at: .fps25)...Timecode(1, 0, 0, 1).frameIndex(at: .fps25))
            .map { Timecode(frameIndex: $0, rate: .fps25) })
        sim.play(from: start, to: Timecode(1, 0, 3, 0), startSeconds: 0, skip: skip)
        #expect(sim.fires.count == 1)
        #expect(sim.fires.first?.via == .catchWindow)
        #expect(sim.fires.first?.lateFrames == 2)
        #expect(sim.misses.isEmpty)
    }

    @Test func dropoutPastTheWindowIsAMiss() {
        let sim = Sim(cues: [Self.song])
        let skip = Set((Timecode(0, 59, 59, 15).frameIndex(at: .fps25)...Timecode(1, 0, 0, 5).frameIndex(at: .fps25))
            .map { Timecode(frameIndex: $0, rate: .fps25) })
        sim.play(from: Timecode(0, 59, 57, 0), to: Timecode(1, 0, 3, 0), startSeconds: 0, skip: skip)
        #expect(sim.fires.isEmpty)
        #expect(sim.misses.count == 1)
    }

    @Test func ltcStartingPastTheWindowMustNotFire() {
        let sim = Sim(cues: [Self.song])
        sim.play(from: Timecode(1, 0, 1, 0), to: Timecode(1, 0, 6, 0), startSeconds: 0)
        sim.silence(2)
        #expect(sim.fires.isEmpty)
        #expect(sim.misses.count == 1)
        #expect(sim.misses.first?.reason.contains("first appeared at 01:00:01:00") == true)
    }

    @Test func ltcStartingOnTheCueWithoutPrerollIsAMiss() {
        // Lock takes 5 frames, so the earliest possible fire would be 4 frames late.
        let sim = Sim(cues: [Self.song])
        sim.play(from: Self.cueTC, to: Timecode(1, 0, 4, 0), startSeconds: 0)
        #expect(sim.fires.isEmpty)
        #expect(sim.misses.count == 1)
    }

    @Test func ltcStoppingBeforeTheCueNeverFires() {
        let sim = Sim(cues: [Self.song])
        sim.play(from: Timecode(0, 59, 57, 0), to: Timecode(0, 59, 59, 19), startSeconds: 0) // stops 6 frames early
        sim.silence(3)
        #expect(sim.fires.isEmpty)
    }

    @Test func secondPassAfterSilenceFiresAgain() {
        let sim = Sim(cues: [Self.song])
        sim.play(from: Timecode(0, 59, 57, 0), to: Timecode(1, 0, 3, 0), startSeconds: 0)
        sim.silence(2)
        sim.play(from: Timecode(0, 59, 57, 0), to: Timecode(1, 0, 3, 0), startSeconds: 10)
        sim.silence(2)
        #expect(sim.fires.count == 2)
        #expect(sim.fires.allSatisfy { $0.via == .exact })
    }

    @Test func backwardJumpReArmsAndFiresAgain() {
        // Continuous LTC that jumps back before the cue (e.g. a rehearsal restart), no silence.
        let sim = Sim(cues: [Self.song])
        sim.play(from: Timecode(0, 59, 57, 0), to: Timecode(1, 0, 2, 0), startSeconds: 0)
        sim.play(from: Timecode(0, 59, 57, 0), to: Timecode(1, 0, 2, 0), startSeconds: 5.04)
        #expect(sim.fires.count == 2)
        #expect(sim.events.contains { if case .unlocked(_, .jump, _) = $0 { return true }; return false })
    }

    @Test func jumpForwardIntoTheWindowCatches() {
        let sim = Sim(cues: [Self.song])
        sim.play(from: Timecode(0, 59, 50, 0), to: Timecode(0, 59, 52, 0), startSeconds: 0)
        // Jump straight to 2 frames after the cue (lock needs 5 frames → too late: miss).
        sim.play(from: Timecode(1, 0, 0, 2), to: Timecode(1, 0, 3, 0), startSeconds: 2.08)
        #expect(sim.fires.isEmpty)
        #expect(sim.misses.count == 1)
    }

    @Test func disabledCuesNeverFire() {
        var cue = Self.song
        cue.enabled = false
        let sim = Sim(cues: [cue])
        sim.play(from: Timecode(0, 59, 57, 0), to: Timecode(1, 0, 3, 0), startSeconds: 0)
        #expect(sim.fires.isEmpty)
        #expect(sim.misses.isEmpty)
    }

    @Test func twoCuesInOnePassBothFire() {
        let a = Cue(name: "A", timecode: Timecode(1, 0, 0, 0), note: 60)
        let b = Cue(name: "B", timecode: Timecode(1, 0, 2, 10), note: 61)
        let sim = Sim(cues: [a, b])
        sim.play(from: Timecode(0, 59, 57, 0), to: Timecode(1, 0, 5, 0), startSeconds: 0)
        #expect(sim.fires.map(\.cue) == ["A", "B"])
    }

    @Test func editingAScheduledCueCancelsIt() {
        let sim = Sim(cues: [Self.song])
        // Stop playback 3 frames before the cue (schedule is pending), then edit the cue.
        sim.play(from: Timecode(0, 59, 57, 0), to: Timecode(0, 59, 59, 21), startSeconds: 0)
        #expect(sim.core.cues.isScheduled(Self.song.id))
        var edited = Self.song
        edited.note = 62
        let actions = sim.core.cues.setCues([edited])
        #expect(actions == [.cancel(Self.song, reason: "cue changed")])
    }
}

/// The real scheduler thread with a recording MIDI sink.
struct FireSchedulerTests {
    static let cue = Cue(name: "Song", timecode: Timecode(1, 0, 0, 0), note: 60, channel: 2, velocity: 100)

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var reports: [FireReport] = []
        func add(_ r: FireReport) { lock.withLock { reports.append(r) } }
        var all: [FireReport] { lock.withLock { reports } }
    }

    @Test func armedSendsNoteOnAtTheExactTimeThenNoteOff() async throws {
        let sink = RecordingMIDISink()
        let scheduler = FireScheduler(sink: sink)
        defer { scheduler.shutdown() }
        let box = Box()
        scheduler.onReport = { box.add($0) }
        scheduler.armed = true
        let target = HostClock.adding(0.05, to: HostClock.now())
        scheduler.schedule(Self.cue, at: target, via: .exact, lateFrames: 0, cueFrameTime: target)
        try await Task.sleep(for: .milliseconds(250))

        let m = sink.messages
        #expect(m.count == 2)
        guard m.count == 2 else { return }
        #expect(m[0].status == 0x91 && m[0].data1 == 60 && m[0].data2 == 100)
        #expect(m[0].hostTime == target)
        let lateness = HostClock.seconds(from: target, to: m[0].sentAt)
        #expect(lateness >= 0 && lateness < 0.002, "sent \(lateness * 1000) ms after target")
        #expect(m[1].status == 0x81 && m[1].data1 == 60 && m[1].data2 == 0)
        let gap = HostClock.seconds(from: m[0].sentAt, to: m[1].sentAt)
        #expect(abs(gap - 0.1) < 0.005)
        #expect(box.all.map(\.kind) == [.fired])
    }

    @Test func disarmedSendsNothingButReportsWouldHaveFired() async throws {
        let sink = RecordingMIDISink()
        let scheduler = FireScheduler(sink: sink)
        defer { scheduler.shutdown() }
        let box = Box()
        scheduler.onReport = { box.add($0) }
        scheduler.armed = false
        scheduler.schedule(Self.cue, at: HostClock.adding(0.02, to: HostClock.now()), via: .exact, lateFrames: 0, cueFrameTime: nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sink.messages.isEmpty)
        #expect(box.all.map(\.kind) == [.wouldHaveFired])
    }

    @Test func cancelledScheduleNeverSends() async throws {
        let sink = RecordingMIDISink()
        let scheduler = FireScheduler(sink: sink)
        defer { scheduler.shutdown() }
        scheduler.armed = true
        scheduler.schedule(Self.cue, at: HostClock.adding(0.05, to: HostClock.now()), via: .exact, lateFrames: 0, cueFrameTime: nil)
        #expect(scheduler.cancel(Self.cue.id))
        try await Task.sleep(for: .milliseconds(150))
        #expect(sink.messages.isEmpty)
    }

    @Test func testFireIgnoresDisarmed() async throws {
        let sink = RecordingMIDISink()
        let scheduler = FireScheduler(sink: sink)
        defer { scheduler.shutdown() }
        scheduler.armed = false
        scheduler.testFire(Self.cue)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sink.messages.map(\.status) == [0x91, 0x81])
    }
}

struct CueStoreTests {
    @Test func roundTripSortAndLogging() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cues-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = EventLog(directory: dir)
        let store = CueStore(fileURL: dir.appendingPathComponent("cues.json"), log: log)
        let late = Cue(name: "Song 3", timecode: Timecode(2, 0, 0, 0), note: 61)
        var early = Cue(name: "Song 2", timecode: Timecode(1, 0, 0, 0), note: 60)
        store.replaceAll([late, early])
        #expect(store.cues.map(\.name) == ["Song 2", "Song 3"])
        early.enabled = false
        store.update { $0[0] = early }
        early.note = 64
        store.update { $0[0] = early }
        log.flush()
        #expect(log.recent().map(\.event) == ["cue.added", "cue.added", "cue.disabled", "cue.edited"])
        let reloaded = CueStore(fileURL: dir.appendingPathComponent("cues.json"), log: nil)
        #expect(reloaded.cues == store.cues)
        let json = String(data: try Data(contentsOf: dir.appendingPathComponent("cues.json")), encoding: .utf8)!
        #expect(json.contains("\"timecode\" : \"01:00:00:00\""))
    }
}

struct OffsetRangeTests {
    @Test func settingsAcceptPlusMinus1000AndClampBeyond() throws {
        let ok = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"offsetMs":-1000}"#.utf8))
        #expect(ok.offsetMs == -1000)
        let big = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"offsetMs":1500}"#.utf8))
        #expect(big.offsetMs == 1000)
    }

    @Test func minus1000FiresOnTimeWithEnoughPreroll() {
        // 1.5 s of pre-roll: lock (~0.2 s) comes well before the fire time (cue − 1 s).
        let sim = Sim(cues: [CueEngineTests.song], offsetMs: -1000)
        let start = Timecode(0, 59, 58, 12)
        sim.play(from: start, to: Timecode(1, 0, 2, 0), startSeconds: 0)
        #expect(sim.fires.count == 1 && sim.fires.first?.via == .exact)
        if let f = sim.fires.first {
            #expect(sim.error(of: f, versus: CueEngineTests.cueTC, firstIndex: start, startSeconds: 0, offsetMs: -1000) < 0.0001)
        }
    }

    @Test func minus1000WithTooLittlePrerollIsAMissNotALateFire() {
        // 0.88 s of pre-roll: the fire time (cue − 1 s) has already passed when lock arrives.
        let sim = Sim(cues: [CueEngineTests.song], offsetMs: -1000)
        sim.play(from: Timecode(0, 59, 59, 3), to: Timecode(1, 0, 2, 0), startSeconds: 0)
        #expect(sim.fires.isEmpty)
        #expect(sim.misses.first?.reason.contains("not enough pre-roll") == true)
    }
}
