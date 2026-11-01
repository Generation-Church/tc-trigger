import CTCCore
import Testing
@testable import TCTriggerKit

/// End-to-end: libltc encoder → real-time C core → LockTracker, offline with synthetic host times.
struct DecodeTests {
    static let base: UInt64 = 10_000_000_000

    struct Decoded {
        var frames: [DecodedFrame]
        var ticksPerSample: Double
    }

    static func decode(_ out: LTCGenerator.Output, chunk: Int = 512) -> Decoded {
        let rt = tc_rt_create(out.sampleRate, 4096)!
        defer { tc_rt_destroy(rt) }
        let tps = tc_rt_ticks_per_sample(rt)
        var frames: [DecodedFrame] = []
        out.samples.withUnsafeBufferPointer { p in
            var pos = 0
            while pos < p.count {
                let n = min(chunk, p.count - pos)
                tc_rt_process(rt, p.baseAddress! + pos, UInt32(n), base + UInt64((Double(pos) * tps).rounded()))
                pos += n
                var f = tc_frame_t()
                while tc_rt_pop_frame(rt, &f) != 0 { frames.append(DecodedFrame(f)) }
            }
        }
        return Decoded(frames: frames, ticksPerSample: tps)
    }

    static func render(_ rate: FrameRate, start: Timecode = Timecode(0, 59, 58, 0), seconds: Double = 4,
                       sampleRate: Double = 48000, dropouts: [(Timecode, Int)] = []) -> LTCGenerator.Output {
        var o = LTCGenerator.Options(rate: rate, start: start, frameCount: Int(seconds * rate.exact))
        o.sampleRate = sampleRate
        o.leadSilence = 0.5
        o.tailSilence = 0.5
        o.dropouts = dropouts
        return LTCGenerator.render(o)
    }

    @Test(arguments: FrameRate.allCases, [44100.0, 48000.0, 96000.0])
    func decodesEveryFrameWithAccurateTiming(rate: FrameRate, sampleRate: Double) {
        let out = Self.render(rate, sampleRate: sampleRate)
        let d = Self.decode(out)
        // The first frame is missed while the decoder learns the signal, and the very last one
        // because LTC needs one more signal edge after a frame to finish reading it.
        #expect(d.frames.count == out.frameStarts.count - 2)
        #expect(d.frames.first?.timecode == Timecode(frameIndex: Timecode(0, 59, 58, 0).frameIndex(at: rate) + 1, rate: rate))

        var worst = 0.0
        for (a, b) in zip(d.frames, d.frames.dropFirst()) {
            #expect(b.timecode.frameIndex(at: rate) == a.timecode.frameIndex(at: rate) + 1)
        }
        for f in d.frames {
            #expect(f.dropFrameFlag == rate.isDropFrame)
            guard let expected = out.frameStarts[f.timecode] else {
                Issue.record("Unexpected timecode \(f.timecode)")
                continue
            }
            let expectedHost = Self.base + UInt64((Double(expected) * d.ticksPerSample).rounded())
            let err = abs(HostClock.seconds(from: expectedHost, to: f.hostTime))
            worst = max(worst, err)
        }
        // Frame start times must be accurate to well under a millisecond.
        #expect(worst < 0.0003, "worst frame-start error \(worst * 1000) ms")
    }

    @Test(arguments: FrameRate.allCases)
    func locksAndDetectsRate(rate: FrameRate) {
        let d = Self.decode(Self.render(rate, seconds: 3))
        let tracker = LockTracker()
        var events: [LTCEvent] = []
        for f in d.frames {
            events += tracker.ingest(f)
            events += tracker.tick(now: f.hostTime)
        }
        let lockIndex = events.firstIndex { if case .locked = $0 { return true }; return false }
        #expect(lockIndex != nil)
        #expect(tracker.isLocked)
        #expect(tracker.rate == rate)
        #expect(!tracker.rateProvisional)
        #expect(!events.contains { if case .unlocked = $0 { return true }; return false })
        #expect(tracker.stats.droppedFrames == 0)
        if let period = tracker.model.period {
            #expect(abs(1 / period - rate.exact) < 0.005)
        }
    }

    @Test(arguments: [FrameRate.fps25, .fps2997DF])
    func shortDropoutKeepsOrRegainsLock(rate: FrameRate) {
        let out = Self.render(rate, start: Timecode(0, 59, 58, 0), seconds: 4,
                              dropouts: [(Timecode(1, 0, 0, 0), 2)])
        let d = Self.decode(out)
        let tracker = LockTracker()
        var events: [LTCEvent] = []
        var lastTick = d.frames.first!.hostTime
        for f in d.frames {
            // Simulate the engine's 2 ms polling between frames.
            while lastTick < f.hostTime {
                events += tracker.tick(now: lastTick)
                lastTick = HostClock.adding(0.002, to: lastTick)
            }
            events += tracker.ingest(f)
        }
        #expect(tracker.isLocked)
        let jumps = events.filter { if case .unlocked(_, .jump, _) = $0 { return true }; return false }
        #expect(jumps.isEmpty)
        // The frames right after the dropout must still be trusted within a few frames.
        let after = d.frames.first { $0.timecode >= Timecode(1, 0, 0, 5) }!
        #expect(after.timecode.frameIndex(at: rate) <= Timecode(1, 0, 0, 5).frameIndex(at: rate) + 1)
    }
}

struct StaleFrameTests {
    /// The last frame of a segment is only decodable when the next segment begins; it must be
    /// dropped rather than reported seconds late (found in the live Background Music test).
    @Test func lastFrameOfPreviousSegmentIsDropped() {
        let a = DecodeTests.render(.fps2997DF, start: Timecode(0, 59, 55, 0), seconds: 2)
        let b = DecodeTests.render(.fps2997DF, start: Timecode(0, 59, 55, 0), seconds: 2)
        let gap = [Float](repeating: 0, count: 48000 * 5)
        let joined = LTCGenerator.Output(samples: a.samples + gap + b.samples, frameStarts: [:], sampleRate: 48000)

        let rt = tc_rt_create(48000, 4096)!
        defer { tc_rt_destroy(rt) }
        let tps = tc_rt_ticks_per_sample(rt)
        var lateness: [Double] = []
        var frames: [DecodedFrame] = []
        joined.samples.withUnsafeBufferPointer { p in
            var pos = 0
            while pos < p.count {
                let n = min(512, p.count - pos)
                tc_rt_process(rt, p.baseAddress! + pos, UInt32(n), DecodeTests.base + UInt64((Double(pos) * tps).rounded()))
                pos += n
                let now = DecodeTests.base + UInt64((Double(pos) * tps).rounded())
                var f = tc_frame_t()
                while tc_rt_pop_frame(rt, &f) != 0 {
                    let d = DecodedFrame(f)
                    frames.append(d)
                    lateness.append(HostClock.seconds(from: d.hostTime, to: now))
                }
            }
        }
        var stats = tc_rt_stats_t()
        tc_rt_get_stats(rt, &stats)
        #expect(stats.stale_frames == 1)
        // Segment A loses its first frame (decoder warming up) and its last (stale); segment B
        // starts with a warmed-up decoder and only loses its last frame.
        #expect(frames.count == (a.frameStarts.count - 2) + (b.frameStarts.count - 1))
        // Every frame reached the engine within ~2 frame periods of its start.
        #expect(lateness.max()! < 0.08)
    }
}
