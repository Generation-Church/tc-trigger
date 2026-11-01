import Foundation

public enum FireVia: String, Sendable {
    /// Scheduled ahead from predicted frame times; fires exactly at cue + offset.
    case exact
    /// The cue frame itself was missed; fired as soon as a frame inside the catch window was heard.
    case catchWindow = "catch window"
}

/// What the cue engine wants done.
public enum CueAction: Equatable, Sendable {
    /// Send this cue at host time `at` (replaces any earlier schedule for the same cue).
    /// `cueFrameTime` is the predicted start of the cue frame (before the offset).
    case schedule(Cue, at: UInt64, cueFrameTime: UInt64, via: FireVia, lateFrames: Int, isUpdate: Bool)
    /// Drop a pending schedule (lock lost or jump before the fire time, or the cue was edited).
    case cancel(Cue, reason: String)
    /// The cue was not fired, and why.
    case missed(Cue, reason: String, heard: Timecode)
    /// The cue frame actually arrived: how far it was from the prediction used to schedule it.
    case timingCheck(Cue, predicted: UInt64, actual: UInt64)
}

/// Decides when each cue fires. Pure logic: fed locked frames and LTC events, returns actions.
///
/// For each enabled cue at frame C with catch window N:
/// - **Scheduled hit:** locked and approaching C → schedule at predicted time of C + offset.
/// - **Catch:** not scheduled, and timecode enters [C, C+N] (first lock, relock, jump, or a skip
///   while locked) → fire as soon as possible.
/// - **Miss:** timecode enters past C+N (within `missLogWindow`), or LTC passes C without lock → log.
/// - Fires once per pass; re-arms when LTC stops (segment end), when timecode moves past C+N, or
///   when it goes back to before where it was when the cue fired (e.g. a rehearsal restart).
public final class CueEngine {
    public struct Config: Equatable, Sendable {
        /// Seconds added to every fire time (positive = later).
        public var offset: Double = 0
        public var catchWindow = 3
        /// How far ahead of the fire time the schedule is handed to the fire scheduler.
        public var lookahead = 0.25
        /// Misses are only logged when LTC appears this soon after a cue (seconds).
        public var missLogWindow = 30.0
        public init() {}
    }

    private enum Phase: Equatable {
        case ready
        case scheduled(at: UInt64)
        case done
    }

    public private(set) var config: Config
    public private(set) var cues: [Cue] = []
    private var phase: [UUID: Phase] = [:]
    private var predicted: [UUID: UInt64] = [:]
    /// Latest locked frame index at the moment each cue fired or missed. Frames decoded just
    /// after a fire are still "before" the cue, so re-arming needs timecode to go back past this.
    private var doneIndex: [UUID: Int] = [:]
    private var handledThisSegment: Set<UUID> = []
    private var prevIndex: Int?
    private var segmentStart: Timecode?
    private var lastRate: FrameRate?

    public init(config: Config = Config()) {
        self.config = config
    }

    public var enabledCues: [Cue] { cues.filter(\.enabled) }

    /// True if this cue has fired (or missed) on the current pass and is waiting to re-arm.
    public func isDone(_ id: UUID) -> Bool { phase[id] == .done }

    public func isScheduled(_ id: UUID) -> Bool {
        if case .scheduled = phase[id] { return true }
        return false
    }

    // MARK: Configuration

    /// Replace the cue list. Pending schedules of removed, disabled or changed cues are cancelled.
    public func setCues(_ new: [Cue]) -> [CueAction] {
        var actions: [CueAction] = []
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        for old in cues {
            let replacement = newByID[old.id]
            let unchanged = replacement.map {
                $0.enabled && $0.timecode == old.timecode && $0.note == old.note
                    && $0.channel == old.channel && $0.velocity == old.velocity
            } ?? false
            if !unchanged {
                if case .scheduled = phase[old.id] {
                    actions.append(.cancel(old, reason: replacement == nil ? "cue deleted" : "cue changed"))
                }
                phase[old.id] = nil
                predicted[old.id] = nil
            }
        }
        cues = new
        return actions
    }

    public func setConfig(_ c: Config) { config = c }

    // MARK: Input

    /// Feed every LTC event from the lock tracker.
    public func handle(_ event: LTCEvent, rate: FrameRate?) -> [CueAction] {
        if let rate { lastRate = rate }
        var actions: [CueAction] = []
        switch event {
        case .segmentStarted(let tc):
            segmentStart = tc
            handledThisSegment.removeAll()

        case let .segmentEnded(start, end, _, _):
            if let rate = lastRate {
                let s = start.frameIndex(at: rate), e = end.frameIndex(at: rate)
                for cue in enabledCues where phase[cue.id, default: .ready] == .ready
                    && !handledThisSegment.contains(cue.id) {
                    let c = cue.timecode.frameIndex(at: rate)
                    if s <= c && c <= e {
                        actions.append(.missed(cue, reason: "LTC passed the cue without lock (heard \(start) → \(end))",
                                               heard: end))
                    }
                }
            }
            // LTC stopped: everything re-arms for the next pass.
            for cue in cues {
                if case .scheduled = phase[cue.id] { actions.append(.cancel(cue, reason: "LTC stopped")) }
                phase[cue.id] = .ready
            }
            predicted.removeAll()
            doneIndex.removeAll()
            handledThisSegment.removeAll()
            prevIndex = nil
            segmentStart = nil

        case let .unlocked(_, reason, _):
            // Lost LTC never triggers anything: pending schedules are withdrawn.
            for cue in cues {
                if case .scheduled = phase[cue.id] {
                    actions.append(.cancel(cue, reason: "lock lost before fire time (\(reason.rawValue))"))
                    phase[cue.id] = .ready
                    predicted[cue.id] = nil
                }
            }
            prevIndex = nil

        case .locked, .rateRefined:
            break
        }
        return actions
    }

    /// Feed every frame that arrives while locked.
    /// - Parameters:
    ///   - justLocked: this is the first locked frame after (re)gaining lock.
    ///   - predict: predicted start host time of a frame index (the tracker's timing model).
    ///   - period: current frame period in seconds.
    public func lockedFrame(index i: Int, hostTime: UInt64, rate: FrameRate, justLocked: Bool, now: UInt64,
                            period: Double, predict: (Int) -> UInt64?) -> [CueAction] {
        lastRate = rate
        var actions: [CueAction] = []
        let n = config.catchWindow
        let missWindowFrames = Int(config.missLogWindow / period)
        let heard = Timecode(frameIndex: i, rate: rate)

        for cue in enabledCues {
            let c = cue.timecode.frameIndex(at: rate)
            var ph = phase[cue.id, default: .ready]

            if i == c, let p = predicted[cue.id] {
                actions.append(.timingCheck(cue, predicted: p, actual: hostTime))
                predicted[cue.id] = nil
            }
            if ph == .done, i > c + n || i < (doneIndex[cue.id] ?? c) - 1 { ph = .ready }

            switch ph {
            case .done:
                break

            case .scheduled(let at):
                // Refine the fire time as more frames arrive.
                if i < c, let p = predict(c) {
                    let target = HostClock.adding(config.offset, to: p)
                    let shift = abs(HostClock.seconds(from: at, to: target))
                    if shift > 0.0002, HostClock.seconds(from: now, to: at) > 0.005 {
                        ph = .scheduled(at: target)
                        predicted[cue.id] = p
                        actions.append(.schedule(cue, at: target, cueFrameTime: p, via: .exact, lateFrames: 0, isUpdate: true))
                    }
                }

            case .ready:
                let crossed = justLocked ? i >= c : (prevIndex.map { $0 < c && i >= c } ?? false)
                if i < c {
                    guard let p = predict(c) else { break }
                    let target = HostClock.adding(config.offset, to: p)
                    let untilFire = HostClock.seconds(from: now, to: target)
                    guard untilFire <= config.lookahead else { break }
                    if untilFire >= -0.002 {
                        ph = .scheduled(at: max(target, now))
                        predicted[cue.id] = p
                        actions.append(.schedule(cue, at: max(target, now), cueFrameTime: p, via: .exact,
                                                 lateFrames: 0, isUpdate: false))
                    } else {
                        // A negative offset reaches back before lock was possible.
                        let late = Int((-untilFire / period).rounded(.up))
                        if late <= n {
                            ph = .scheduled(at: now)
                            actions.append(.schedule(cue, at: now, cueFrameTime: p, via: .catchWindow,
                                                     lateFrames: late, isUpdate: false))
                        } else {
                            ph = .done
                            doneIndex[cue.id] = i
                            actions.append(.missed(cue, reason: "not enough pre-roll before the cue for the \(Int(config.offset * 1000)) ms offset (locked at \(heard))", heard: heard))
                        }
                        handledThisSegment.insert(cue.id)
                    }
                } else if crossed {
                    let late = i - c
                    if late <= n {
                        let p = predict(c) ?? hostTime
                        let target = HostClock.adding(config.offset, to: p)
                        let onTime = HostClock.seconds(from: now, to: target) > 0
                        let at = onTime ? target : now
                        ph = .scheduled(at: at)
                        if onTime { predicted[cue.id] = p }
                        actions.append(.schedule(cue, at: at, cueFrameTime: p, via: onTime ? .exact : .catchWindow,
                                                 lateFrames: late, isUpdate: false))
                        handledThisSegment.insert(cue.id)
                    } else if late <= missWindowFrames {
                        ph = .done
                        doneIndex[cue.id] = i
                        handledThisSegment.insert(cue.id)
                        actions.append(.missed(cue, reason: missReason(cue: c, heard: i, rate: rate, justLocked: justLocked),
                                               heard: heard))
                    }
                }
            }
            phase[cue.id] = ph
        }
        prevIndex = i
        return actions
    }

    /// Call regularly: schedules whose time has passed count as fired for this pass.
    public func tick(now: UInt64) {
        for (id, ph) in phase {
            if case .scheduled(let at) = ph, at <= now {
                phase[id] = .done
                doneIndex[id] = prevIndex ?? doneIndex[id]
                handledThisSegment.insert(id)
            }
        }
    }

    /// Withdraw every pending schedule (they become ready again, so a catch is still possible).
    public func cancelPending(reason: String) -> [CueAction] {
        var actions: [CueAction] = []
        for cue in cues {
            if case .scheduled = phase[cue.id] {
                actions.append(.cancel(cue, reason: reason))
                phase[cue.id] = .ready
                predicted[cue.id] = nil
            }
        }
        return actions
    }

    public var hasPending: Bool {
        phase.values.contains { if case .scheduled = $0 { return true }; return false }
    }

    /// The scheduler fired (or would have fired) this cue.
    public func markFired(_ id: UUID) {
        if phase[id] != .done { doneIndex[id] = prevIndex ?? doneIndex[id] }
        phase[id] = .done
        handledThisSegment.insert(id)
    }

    private func missReason(cue c: Int, heard i: Int, rate: FrameRate, justLocked: Bool) -> String {
        let n = config.catchWindow
        let at = Timecode(frameIndex: i, rate: rate)
        guard justLocked else {
            return "frames around the cue were not received; next frame was \(at), \(i - c) frames after the cue (catch window \(n))"
        }
        if let s = segmentStart, s.frameIndex(at: rate) < c {
            return "LTC was heard from \(s) but lock wasn't achieved until \(at), \(i - c) frames after the cue (catch window \(n))"
        }
        let first = segmentStart ?? at
        return "LTC first appeared at \(first), \(first.frameIndex(at: rate) - c) frames after the cue; locked at \(at), \(i - c) frames late (catch window \(n))"
    }
}
