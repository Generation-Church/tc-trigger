import Darwin
import Foundation

/// What happened when a scheduled cue's time came.
public struct FireReport: Sendable {
    public enum Kind: String, Sendable {
        case fired
        /// Disarmed: nothing was sent.
        case wouldHaveFired = "would have fired"
        /// Test Fire from the UI (ignores timecode and armed state).
        case test
        /// Fire Next Cue (UI or MIDI control): sends regardless of timecode and armed state.
        case manual
    }

    public let cue: Cue
    public let kind: Kind
    public let via: FireVia?
    public let lateFrames: Int
    /// Host time the note was meant to go out.
    public let target: UInt64
    /// Host time it actually went out (or would have).
    public let sentAt: UInt64
    /// When the schedule was last set or updated.
    public let scheduledAt: UInt64
    /// Predicted start of the cue frame (before offset), if timecode-driven.
    public let cueFrameTime: UInt64?
}

/// A dedicated high-priority thread that sends each cue's note at exactly its host time.
///
/// It waits coarsely on a condition until ~3 ms before the target, then `mach_wait_until`s the
/// exact time (accurate to tens of microseconds with time-constraint scheduling), sends the
/// note-on, and queues the note-off 100 ms later. It does nothing else, so nothing can delay it.
public final class FireScheduler: @unchecked Sendable {
    public static let noteOffDelay = 0.1

    private enum Payload {
        case cue(Cue, via: FireVia?, lateFrames: Int, cueFrameTime: UInt64?, scheduledAt: UInt64, forced: FireReport.Kind?)
        case noteOff(channel: Int, note: Int)
    }

    private struct Item {
        let seq: Int
        let at: UInt64
        let key: UUID?
        let payload: Payload
    }

    private let sink: MIDISink?
    private let cond = NSCondition()
    private var items: [Item] = []
    private var nextSeq = 0
    private var running = true
    private var _armed = false
    private var thread: Thread?

    /// Called on the scheduler thread after each cue fires (keep it quick: hop to another queue).
    public var onReport: ((FireReport) -> Void)?

    public init(sink: MIDISink?) {
        self.sink = sink
        let t = Thread { [weak self] in self?.run() }
        t.name = "TC Trigger fire scheduler"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    deinit { shutdown() }

    public func shutdown() {
        cond.lock()
        running = false
        cond.signal()
        cond.unlock()
    }

    /// Whether cues send MIDI. Read at the moment of firing.
    public var armed: Bool {
        get { cond.lock(); defer { cond.unlock() }; return _armed }
        set { cond.lock(); _armed = newValue; cond.unlock() }
    }

    /// Schedule (or move) a cue. Replaces any pending schedule for the same cue.
    public func schedule(_ cue: Cue, at: UInt64, via: FireVia, lateFrames: Int, cueFrameTime: UInt64?) {
        cond.lock()
        items.removeAll { $0.key == cue.id }
        add(at: at, key: cue.id, payload: .cue(cue, via: via, lateFrames: lateFrames, cueFrameTime: cueFrameTime,
                                              scheduledAt: HostClock.now(), forced: nil))
        cond.signal()
        cond.unlock()
    }

    /// Withdraw a pending cue. Returns false if it had already gone out.
    @discardableResult
    public func cancel(_ id: UUID) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        let before = items.count
        items.removeAll { $0.key == id }
        return items.count != before
    }

    public func cancelAll() {
        cond.lock()
        items.removeAll { $0.key != nil }
        cond.unlock()
    }

    /// Send a cue right now regardless of timecode and armed state (Test Fire).
    public func testFire(_ cue: Cue) { fireNow(cue, kind: .test) }

    /// Fire Next Cue: send now regardless of timecode and armed state; counts as the cue's fire.
    public func manualFire(_ cue: Cue) {
        cond.lock()
        items.removeAll { $0.key == cue.id } // supersedes any pending timecode schedule
        cond.unlock()
        fireNow(cue, kind: .manual)
    }

    private func fireNow(_ cue: Cue, kind: FireReport.Kind) {
        cond.lock()
        let now = HostClock.now()
        add(at: now, key: nil, payload: .cue(cue, via: nil, lateFrames: 0, cueFrameTime: nil, scheduledAt: now, forced: kind))
        cond.signal()
        cond.unlock()
    }

    /// Send raw messages immediately (Panic, LED feedback).
    public func sendNow(_ messages: [(UInt8, UInt8, UInt8)]) {
        let now = HostClock.now()
        for m in messages { sink?.send(m.0, m.1, m.2, hostTime: now) }
    }

    public var pendingCount: Int {
        cond.lock(); defer { cond.unlock() }
        return items.filter { $0.key != nil }.count
    }

    // MARK: Thread

    /// Must hold `cond`.
    private func add(at: UInt64, key: UUID?, payload: Payload) {
        items.append(Item(seq: nextSeq, at: at, key: key, payload: payload))
        nextSeq += 1
    }

    private func run() {
        Self.makeTimeConstrained()
        cond.lock()
        while running {
            guard let next = items.min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }) else {
                cond.wait()
                continue
            }
            let now = HostClock.now()
            if next.at > now {
                let wait = HostClock.seconds(from: now, to: next.at)
                if wait > 0.004 {
                    // Coarse wait; wakes early if something new is scheduled.
                    _ = cond.wait(until: Date().addingTimeInterval(wait - 0.003))
                    continue
                }
                cond.unlock()
                mach_wait_until(next.at)
                cond.lock()
                // It may have been cancelled or moved while we waited.
                guard items.contains(where: { $0.seq == next.seq }) else { continue }
            }
            items.removeAll { $0.seq == next.seq }
            let armedNow = _armed
            cond.unlock()
            perform(next, armed: armedNow)
            cond.lock()
        }
        cond.unlock()
    }

    private func perform(_ item: Item, armed: Bool) {
        switch item.payload {
        case let .noteOff(channel, note):
            sink?.send(0x80 | UInt8(channel - 1), UInt8(note), 0, hostTime: item.at)

        case let .cue(cue, via, lateFrames, cueFrameTime, scheduledAt, forced):
            let send = armed || forced != nil
            let sentAt: UInt64
            if send {
                // Stamp with the intended time (receivers that honour timestamps line up exactly).
                sink?.send(0x90 | UInt8(cue.channel - 1), UInt8(cue.note), UInt8(cue.velocity), hostTime: item.at)
                sentAt = HostClock.now()
                cond.lock()
                add(at: HostClock.adding(Self.noteOffDelay, to: sentAt), key: nil,
                    payload: .noteOff(channel: cue.channel, note: cue.note))
                cond.unlock()
            } else {
                sentAt = HostClock.now()
            }
            let kind: FireReport.Kind = forced ?? (armed ? .fired : .wouldHaveFired)
            onReport?(FireReport(cue: cue, kind: kind, via: via, lateFrames: lateFrames, target: item.at,
                                 sentAt: sentAt, scheduledAt: scheduledAt, cueFrameTime: cueFrameTime))
        }
    }

    /// Ask the kernel for real-time scheduling for this thread.
    private static func makeTimeConstrained() {
        let ticksPerMs = HostClock.ticksPerSecond / 1000
        var policy = thread_time_constraint_policy_data_t(
            period: 0,
            computation: UInt32(0.5 * ticksPerMs),
            constraint: UInt32(2 * ticksPerMs),
            preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
    }
}
