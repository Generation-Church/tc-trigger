/// Lock tracker + cue engine, wired together exactly as the live engine uses them.
/// No threads, clocks or MIDI here, so tests can drive it with hand-made frames and times.
public final class TriggerCore {
    public let tracker: LockTracker
    public let cues: CueEngine

    public init(lockConfig: LockTracker.Config = .init(), cueConfig: CueEngine.Config = .init()) {
        tracker = LockTracker(config: lockConfig)
        cues = CueEngine(config: cueConfig)
    }

    /// When the most recent frame was dequeued.
    private var lastArrival: UInt64?

    public struct Output {
        public var ltcEvents: [LTCEvent] = []
        public var actions: [CueAction] = []
    }

    /// Process one decoded frame. `now` is the current host time (when the frame was dequeued).
    public func ingest(_ frame: DecodedFrame, now: UInt64) -> Output {
        var out = Output()
        lastArrival = now
        out.ltcEvents = tracker.ingest(frame)
        var justLocked = false
        for e in out.ltcEvents {
            if case .locked = e { justLocked = true }
            out.actions += cues.handle(e, rate: tracker.rate)
        }
        if tracker.isLocked, let rate = tracker.rate, let index = tracker.lastLockedIndex {
            let model = tracker.model
            out.actions += cues.lockedFrame(index: index, hostTime: frame.hostTime, rate: rate, justLocked: justLocked,
                                            now: now, period: model.period ?? 1 / rate.exact,
                                            predict: { model.predict(index: $0) })
        }
        return out
    }

    /// Periodic housekeeping (signal loss, segment end, schedules that have passed).
    public func tick(now: UInt64) -> Output {
        var out = Output()
        out.ltcEvents = tracker.tick(now: now)
        for e in out.ltcEvents {
            out.actions += cues.handle(e, rate: tracker.rate)
        }
        // A schedule is only trusted while LTC keeps arriving: if it stops more than ~3 frames
        // before the fire time, withdraw (a 1–2 frame glitch at the cue still fires).
        if cues.hasPending, let last = lastArrival {
            let period = tracker.model.period ?? 1 / 25
            if HostClock.seconds(from: last, to: now) > 3 * period + 0.03 {
                out.actions += cues.cancelPending(reason: "LTC stopped just before the fire time")
            }
        }
        cues.tick(now: now)
        return out
    }

    /// Predicted fire time of a cue on the current pass, if locked and the cue is still ahead.
    public func predictedFireTime(of cue: Cue) -> UInt64? {
        guard tracker.isLocked, let rate = tracker.rate, let index = tracker.lastLockedIndex else { return nil }
        let c = cue.timecode.frameIndex(at: rate)
        guard c >= index, let p = tracker.model.predict(index: c) else { return nil }
        return HostClock.adding(cues.config.offset, to: p)
    }
}
