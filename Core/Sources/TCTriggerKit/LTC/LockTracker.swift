import Foundation

/// Something noteworthy that happened to the incoming LTC.
public enum LTCEvent: Equatable, Sendable {
    /// LTC started being heard after a silence.
    case segmentStarted(Timecode)
    /// LTC stopped (no frames for `segmentGap`).
    case segmentEnded(start: Timecode, end: Timecode, duration: Double, frames: Int)
    /// Enough sequential frames were heard to trust the timecode.
    /// `quick` is true when lock was resumed instantly after a short dropout.
    case locked(Timecode, FrameRate, provisional: Bool, quick: Bool)
    case unlocked(lastTimecode: Timecode, reason: UnlockReason, lockedFor: Double)
    /// The 29.97 vs 30 NDF decision was made (or changed) by measuring the frame period.
    case rateRefined(FrameRate, measuredFPS: Double)
}

public enum UnlockReason: String, Sendable {
    case signalLost = "signal lost"
    case jump = "timecode jump"
    case reverse = "reverse playback"
}

public enum LockState: String, Sendable {
    case noSignal = "No signal"
    case acquiring = "Acquiring"
    case locked = "Locked"
}

/// Decode statistics, mostly for verbose logging.
public struct LockStats: Equatable, Sendable {
    public var frames = 0
    public var outOfSequence = 0
    public var droppedFrames = 0
    public var lockFailures = 0
}

/// Turns a stream of decoded frames into a trusted, locked timecode.
///
/// Rules:
/// - Lock requires `lockFrames` consecutive, sequential frames, each about one frame apart.
/// - While locked, a frame must land where the timing model predicts (a skipped frame or two
///   is fine and counted as dropped); anything else is a jump and drops lock.
/// - Lock is lost if no frame arrives for `lossTimeoutFrames` frame periods.
/// - After a short dropout (not a jump), a single frame that lands exactly where the old lock
///   predicts re-locks immediately ("quick relock").
public final class LockTracker {
    public struct Config: Sendable {
        public var lockFrames = 5
        public var lossTimeoutFrames = 3.0
        public var quickRelockWindow = 2.0
        public var segmentGap = 1.0
        public init() {}
    }

    public let config: Config
    public private(set) var state: LockState = .noSignal
    public private(set) var rate: FrameRate?
    /// True while 30 fps non-drop vs 29.97 NDF is still being measured.
    public private(set) var rateProvisional = false
    public private(set) var lastFrame: DecodedFrame?
    public private(set) var stats = LockStats()
    public private(set) var model = TimingModel()

    private var run: [DecodedFrame] = []
    private var lockedSince: UInt64?
    private var lockedIndex = 0
    private var maxFrameNumber = 0
    private var quickRelock: (index: Int, time: UInt64, rate: FrameRate, provisional: Bool)?
    private var segmentStart: (tc: Timecode, time: UInt64)?
    private var segmentFrames = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    public var isLocked: Bool { state == .locked }

    /// Index of the most recent locked frame (at the current rate).
    public var lastLockedIndex: Int? { state == .locked ? lockedIndex : nil }

    // MARK: Input

    public func ingest(_ f: DecodedFrame) -> [LTCEvent] {
        var events: [LTCEvent] = []
        stats.frames += 1

        if segmentStart == nil {
            segmentStart = (f.timecode, f.hostTime)
            segmentFrames = 0
            maxFrameNumber = 0
            events.append(.segmentStarted(f.timecode))
        }
        segmentFrames += 1
        maxFrameNumber = max(maxFrameNumber, f.timecode.frames)
        defer { lastFrame = f }

        if f.reverse {
            stats.outOfSequence += 1
            if state == .locked { events.append(unlock(.reverse, at: f)) }
            run.removeAll()
            return events
        }

        switch state {
        case .locked:
            events += ingestLocked(f)
        case .noSignal, .acquiring:
            state = .acquiring
            events += ingestAcquiring(f)
        }
        return events
    }

    /// Call regularly (every few ms) with the current host time to detect signal loss.
    public func tick(now: UInt64) -> [LTCEvent] {
        var events: [LTCEvent] = []
        guard let last = lastFrame else { return events }
        let silence = HostClock.seconds(from: last.hostTime, to: now)
        let period = model.period ?? (1.0 / Double(rate?.nominal ?? 25))

        if state == .locked {
            // A frame is only decoded once it has fully arrived, plus audio buffer latency.
            let timeout = period * (1 + config.lossTimeoutFrames) + 0.05
            if silence > timeout {
                events.append(unlock(.signalLost, at: last))
            }
        } else if state == .acquiring, silence > 0.25 {
            run.removeAll()
        }

        if let seg = segmentStart, silence > config.segmentGap {
            let duration = HostClock.seconds(from: seg.time, to: last.hostTime) + period
            events.append(.segmentEnded(start: seg.tc, end: last.timecode, duration: duration,
                                        frames: segmentFrames))
            segmentStart = nil
            state = .noSignal
            run.removeAll()
        }
        return events
    }

    // MARK: Locked

    private func ingestLocked(_ f: DecodedFrame) -> [LTCEvent] {
        guard let rate, let last = lastFrame else { return [] }
        var events: [LTCEvent] = []
        let index = f.timecode.frameIndex(at: rate)
        let period = model.period ?? 1.0 / rate.exact
        let elapsedFrames = HostClock.seconds(from: last.hostTime, to: f.hostTime) / period
        let step = index - lockedIndex

        if f.timecode.isValid(at: rate), step >= 1, step <= 4,
           abs(elapsedFrames - Double(step)) < 0.35 {
            stats.droppedFrames += step - 1
            lockedIndex = index
            model.add(index: index, time: f.hostTime)
            if let refined = refineRate() { events.append(refined) }
            return events
        }

        // Anything else is a jump: drop lock and start acquiring from this frame.
        stats.outOfSequence += 1
        events.append(unlock(.jump, at: last))
        state = .acquiring
        run = [f]
        return events
    }

    private func unlock(_ reason: UnlockReason, at last: DecodedFrame) -> LTCEvent {
        let lockedFor = lockedSince.map { HostClock.seconds(from: $0, to: last.hostTime) } ?? 0
        if reason == .signalLost, let rate {
            quickRelock = (lockedIndex, last.hostTime, rate, rateProvisional)
        } else {
            quickRelock = nil
            model.reset()
        }
        state = .acquiring
        lockedSince = nil
        run.removeAll()
        return .unlocked(lastTimecode: last.timecode, reason: reason, lockedFor: lockedFor)
    }

    // MARK: Acquiring

    private func ingestAcquiring(_ f: DecodedFrame) -> [LTCEvent] {
        // Quick relock after a short dropout: one frame exactly where the old lock predicts.
        if let q = quickRelock {
            let gap = HostClock.seconds(from: q.time, to: f.hostTime)
            if gap > 0, gap < config.quickRelockWindow, let period = model.period {
                let index = f.timecode.frameIndex(at: q.rate)
                let expected = Double(q.index) + gap / period
                if f.timecode.isValid(at: q.rate), abs(Double(index) - expected) < 0.35 {
                    rate = q.rate
                    rateProvisional = q.provisional
                    quickRelock = nil
                    return [becomeLocked(at: f, index: index, quick: true)]
                }
            }
            if gap >= config.quickRelockWindow || gap <= 0 {
                quickRelock = nil
                model.reset()
            }
        }

        if let prev = run.last {
            let dt = HostClock.seconds(from: prev.hostTime, to: f.hostTime)
            if dt < 0.025 || dt > 0.06 {
                // Not one frame apart (gap, glitch or garbage): start over.
                if run.count > 1 { stats.lockFailures += 1 }
                run = [f]
                return []
            }
        }
        run.append(f)
        guard run.count >= 2 else { return [] }

        guard let candidate = classifyRate() else {
            stats.lockFailures += 1
            run = [f]
            return []
        }
        // Every frame in the run must be exactly one frame after the previous one.
        for (a, b) in zip(run, run.dropFirst()) {
            let ia = a.timecode.frameIndex(at: candidate)
            let ib = b.timecode.frameIndex(at: candidate)
            if ib != ia + 1 || !b.timecode.isValid(at: candidate) {
                stats.outOfSequence += 1
                stats.lockFailures += 1
                run = [f]
                return []
            }
        }
        guard run.count >= config.lockFrames else { return [] }

        rate = candidate
        rateProvisional = candidate == .fps30
        model.reset()
        for frame in run {
            model.add(index: frame.timecode.frameIndex(at: candidate), time: frame.hostTime)
        }
        let index = f.timecode.frameIndex(at: candidate)
        run.removeAll()
        return [becomeLocked(at: f, index: index, quick: false)]
    }

    private func becomeLocked(at f: DecodedFrame, index: Int, quick: Bool) -> LTCEvent {
        state = .locked
        lockedIndex = index
        lockedSince = f.hostTime
        if quick { model.add(index: index, time: f.hostTime) }
        return .locked(f.timecode, rate!, provisional: rateProvisional, quick: quick)
    }

    /// Picks 24 / 25 / 30-class from the measured spacing, cross-checked with frame numbers
    /// and the drop-frame flag. 30-class without the DF flag starts as provisional 30.
    private func classifyRate() -> FrameRate? {
        guard let first = run.first, let last = run.last, run.count >= 2 else { return nil }
        let mean = HostClock.seconds(from: first.hostTime, to: last.hostTime) / Double(run.count - 1)
        let candidates: [(Int, Double)] = [(24, 1.0 / 24), (25, 1.0 / 25), (30, 1001.0 / 30000)]
        guard let best = candidates.min(by: { abs($0.1 - mean) < abs($1.1 - mean) }),
              abs(best.1 - mean) / best.1 < 0.03 else { return nil }
        var nominal = best.0
        if maxFrameNumber >= 25 { nominal = 30 } else if maxFrameNumber >= 24, nominal == 24 { nominal = 25 }
        let df = run.contains { $0.dropFrameFlag }
        switch nominal {
        case 24: return df ? nil : .fps24
        case 25: return df ? nil : .fps25
        default: return df ? .fps2997DF : (rate == .fps2997NDF ? .fps2997NDF : .fps30)
        }
    }

    /// Decides 29.97 NDF vs 30 once about a second of frames has been measured.
    private func refineRate() -> LTCEvent? {
        guard rateProvisional, model.count >= 30, model.span >= 0.9,
              let period = model.period else { return nil }
        let measured = 1.0 / period
        let decided: FrameRate = measured < 29.985 ? .fps2997NDF : .fps30
        rate = decided
        rateProvisional = false
        return .rateRefined(decided, measuredFPS: measured)
    }
}
