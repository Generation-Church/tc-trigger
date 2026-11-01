import Testing
@testable import TCTriggerKit

/// LockTracker with hand-made frames (no audio).
struct LockTrackerTests {
    static let base: UInt64 = 50_000_000_000

    /// Frames for consecutive indices, starting `startSeconds` after `base`.
    static func frames(_ rate: FrameRate, from index: Int, count: Int, startSeconds: Double = 0) -> [DecodedFrame] {
        (0..<count).map { i in
            let t = HostClock.adding(startSeconds + Double(i) / rate.exact, to: base)
            return DecodedFrame(timecode: Timecode(frameIndex: index + i, rate: rate),
                                dropFrameFlag: rate.isDropFrame, hostTime: t)
        }
    }

    static func feed(_ tracker: LockTracker, _ frames: [DecodedFrame]) -> [LTCEvent] {
        frames.flatMap { f in tracker.ingest(f) + tracker.tick(now: f.hostTime) }
    }

    @Test func locksAfterFiveSequentialFrames() {
        let t = LockTracker()
        let f = Self.frames(.fps25, from: 90000, count: 6)
        var events: [LTCEvent] = []
        for (i, frame) in f.enumerated() {
            events += t.ingest(frame)
            #expect(t.isLocked == (i >= 4), "frame \(i)")
        }
        #expect(events.first == .segmentStarted(Timecode(1, 0, 0, 0)))
        #expect(events.contains(.locked(Timecode(1, 0, 0, 4), .fps25, provisional: false, quick: false)))
    }

    @Test func outOfOrderFramesNeverLock() {
        let t = LockTracker()
        var f = Self.frames(.fps25, from: 1000, count: 20)
        for i in stride(from: 0, to: 20, by: 2) { f[i].timecode = Timecode(frameIndex: 5000 + i, rate: .fps25) }
        _ = Self.feed(t, f)
        #expect(!t.isLocked)
        #expect(t.stats.lockFailures > 0)
    }

    @Test func jumpUnlocksAndRelocks() {
        let t = LockTracker()
        _ = Self.feed(t, Self.frames(.fps30, from: 1000, count: 10))
        #expect(t.isLocked)
        let jumped = Self.frames(.fps30, from: 5000, count: 5, startSeconds: 10.0 / 30)
        let events = Self.feed(t, jumped)
        #expect(events.contains { if case .unlocked(_, .jump, _) = $0 { return true }; return false })
        #expect(t.isLocked) // the 5 frames after the jump re-acquire lock
        #expect(t.lastLockedIndex == 5004)
    }

    @Test func singleDroppedFrameStaysLocked() {
        let t = LockTracker()
        var f = Self.frames(.fps25, from: 1000, count: 20)
        f.remove(at: 12)
        let events = Self.feed(t, f)
        #expect(t.isLocked)
        #expect(t.stats.droppedFrames == 1)
        #expect(!events.contains { if case .unlocked = $0 { return true }; return false })
    }

    @Test func signalLossThenQuickRelock() {
        let t = LockTracker()
        let first = Self.frames(.fps25, from: 1000, count: 10)
        _ = Self.feed(t, first)
        let last = first.last!.hostTime
        // 300 ms of silence → lock lost.
        let lost = t.tick(now: HostClock.adding(0.3, to: last))
        #expect(lost.contains { if case .unlocked(_, .signalLost, _) = $0 { return true }; return false })
        #expect(!t.isLocked)
        // LTC returns exactly where it should be 0.5 s later: one frame relocks.
        let resumed = Self.frames(.fps25, from: 1000 + 9 + 13, count: 1, startSeconds: 22.0 / 25)
        let ev = t.ingest(resumed[0])
        #expect(ev.contains(.locked(resumed[0].timecode, .fps25, provisional: false, quick: true)))
    }

    @Test func quickRelockRefusesWrongPosition() {
        let t = LockTracker()
        _ = Self.feed(t, Self.frames(.fps25, from: 1000, count: 10))
        _ = t.tick(now: HostClock.adding(0.7, to: Self.base))
        let wrong = Self.frames(.fps25, from: 1000 + 30, count: 1, startSeconds: 22.0 / 25)
        _ = t.ingest(wrong[0])
        #expect(!t.isLocked)
    }

    @Test func segmentEndsAfterOneSecondOfSilence() {
        let t = LockTracker()
        let f = Self.frames(.fps25, from: 90000, count: 50) // 2 s
        _ = Self.feed(t, f)
        #expect(t.tick(now: HostClock.adding(0.9, to: f.last!.hostTime)).allSatisfy {
            if case .segmentEnded = $0 { return false }; return true
        })
        let ev = t.tick(now: HostClock.adding(1.1, to: f.last!.hostTime))
        guard case let .segmentEnded(start, end, duration, frames)? = ev.last else {
            Issue.record("no segment end: \(ev)")
            return
        }
        #expect(start == Timecode(1, 0, 0, 0))
        #expect(end == Timecode(1, 0, 1, 24))
        #expect(abs(duration - 2.0) < 0.001)
        #expect(frames == 50)
        #expect(t.state == .noSignal)
    }

    @Test func distinguishes2997NDFFrom30() {
        for rate in [FrameRate.fps2997NDF, .fps30] {
            let t = LockTracker()
            let events = Self.feed(t, Self.frames(rate, from: 1000, count: 45))
            #expect(t.rate == rate)
            #expect(events.contains { if case .rateRefined(rate, _) = $0 { return true }; return false })
        }
    }

    @Test func reverseFramesUnlock() {
        let t = LockTracker()
        var f = Self.frames(.fps25, from: 1000, count: 12)
        f[10].reverse = true
        let events = Self.feed(t, f)
        #expect(events.contains { if case .unlocked(_, .reverse, _) = $0 { return true }; return false })
    }
}
