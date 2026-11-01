import CoreAudio
import CTCCore
import Foundation
import os

public enum AudioStatus: Equatable, Sendable {
    case stopped
    case running
    case waitingForDevice(String)
    case error(String)

    public var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .running: return "Running"
        case .waitingForDevice(let name): return "Waiting for \(name)"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

/// What the UI shows. Copied out of the engine about 30 times a second.
public struct EngineSnapshot: Equatable, Sendable {
    public var audioStatus: AudioStatus = .stopped
    public var input: AudioInputInfo?
    /// Input peak level in dBFS (with meter-style fall-off).
    public var inputLevelDb: Double = -120
    public var lockState: LockState = .noSignal
    public var timecode: Timecode?
    public var dropFrame = false
    public var rate: FrameRate?
    public var rateProvisional = false
    /// LTC level measured by the decoder, dBFS.
    public var ltcLevelDb: Double?
    public var stats = LockStats()
    public var armed = false
    /// The next enabled cue ahead of the current position (or after the last one fired).
    public var nextCue: Cue?
    /// Seconds until the next cue fires (only while locked and approaching).
    public var nextCueCountdown: Double?
    public var lastFire: FireReport?
    /// Bumped on every fire, so the UI can flash.
    public var fireCount = 0
    /// The cue Fire Next counts from.
    public var lastFireCueIDForNext: UUID?

    public init() {}
}

extension FireReport: Equatable {
    public static func == (a: FireReport, b: FireReport) -> Bool {
        a.cue == b.cue && a.kind == b.kind && a.sentAt == b.sentAt
    }
}

/// Owns the audio input, the lock tracker and cue engine (TriggerCore) and the fire scheduler.
/// All work happens on one high-priority serial queue that polls the real-time ring every 2 ms.
public final class LTCEngine: @unchecked Sendable {
    public let queue = DispatchQueue(label: "church.generation.tctrigger.engine", qos: .userInteractive)
    private let log: EventLog
    private let input = AudioInput()
    private let core: TriggerCore
    private var tracker: LockTracker { core.tracker }
    private let scheduler: FireScheduler
    private var allCues: [Cue] = []
    private var lastFiredCueID: UUID?
    private var watcher: AudioDeviceWatcher?
    private var timer: DispatchSourceTimer?

    private var wantedUID: String?
    private var wantedName: String?
    private var wantedChannel = 1
    private var running = false
    private var lastPoll: UInt64 = 0
    private var lastSecond: UInt64 = 0
    private var lastRTStats = tc_rt_stats_t()
    private var levelDb = -120.0
    private var ltcLevelSum = 0.0
    private var ltcLevelCount = 0

    private let snapshotLock = OSAllocatedUnfairLock(initialState: EngineSnapshot())
    private var snap = EngineSnapshot()

    public init(log: EventLog, midi: MIDISink?, lockConfig: LockTracker.Config = .init()) {
        self.log = log
        self.core = TriggerCore(lockConfig: lockConfig)
        self.scheduler = FireScheduler(sink: midi)
        scheduler.onReport = { [weak self] report in
            guard let self else { return }
            self.queue.async { self.handleReport(report) }
        }
    }

    // MARK: Cues, timing and arming

    public func setCues(_ cues: [Cue]) {
        queue.async {
            self.allCues = cues
            self.perform(self.core.cues.setCues(cues))
        }
    }

    public func setTiming(offsetMs: Int, catchWindowFrames: Int) {
        queue.async {
            var c = self.core.cues.config
            c.offset = Double(offsetMs) / 1000
            c.catchWindow = catchWindowFrames
            self.core.cues.setConfig(c)
        }
    }

    /// Arm or disarm. `source` is recorded in the log ("ui", "midi", "app launch").
    public func setArmed(_ armed: Bool, source: String) {
        queue.async {
            let was = self.scheduler.armed
            self.scheduler.armed = armed
            self.snap.armed = armed
            self.publish()
            if was != armed || source == "app launch" {
                self.log.info(.cue, armed ? "app.armed" : "app.disarmed", armed ? "Armed" : "Disarmed",
                              ["source": .string(source)])
            }
        }
    }

    /// Fire the next enabled cue after the last one fired (or the first), regardless of timecode
    /// and armed state. `source` is "ui" or "midi".
    public func fireNext(source: String) {
        queue.async {
            guard let cue = nextCueToFire(after: self.lastFiredCueID, in: self.allCues) else {
                self.log.warning(.cue, "manual.fire_next_none", "Fire Next Cue: there is no next enabled cue",
                                 ["source": .string(source)])
                return
            }
            self.log.info(.cue, "manual.fire_next", "Fire Next Cue (\(source)): \(cue.name)",
                          cue.logFields.merging(["source": .string(source), "armed": .bool(self.snap.armed)]) { a, _ in a })
            self.core.cues.markFired(cue.id)
            self.lastFiredCueID = cue.id
            self.scheduler.manualFire(cue)
        }
    }

    /// Note-offs for every cue note, All Notes Off on all channels, and cancel pending fires.
    public func panic(source: String) {
        queue.async {
            let cancelled = self.scheduler.pendingCount
            self.scheduler.cancelAll()
            _ = self.core.cues.cancelPending(reason: "Panic")
            let messages = MIDIMessages.panic(cues: self.allCues)
            self.scheduler.sendNow(messages.map { ($0.status, $0.data1, $0.data2) })
            self.log.warning(.midi, "manual.panic", "PANIC (\(source)): sent \(messages.count) note-off messages, cancelled \(cancelled) pending cue\(cancelled == 1 ? "" : "s")",
                             ["source": .string(source), "messages": .int(messages.count), "cancelled": .int(cancelled)])
        }
    }

    /// Send a cue's MIDI immediately, ignoring timecode and armed state.
    public func testFire(_ cue: Cue) {
        log.info(.cue, "cue.test_fire", "Test Fire: \(cue.name) (note \(cue.note) ch \(cue.channel) vel \(cue.velocity))",
                 cue.logFields.merging(["source": "ui"]) { a, _ in a })
        scheduler.testFire(cue)
    }

    public func snapshot() -> EngineSnapshot { snapshotLock.withLock { $0 } }

    /// Choose the input. `uid == nil` follows the system default input.
    public func configure(deviceUID uid: String?, deviceName: String?, channel: Int) {
        queue.async {
            self.wantedUID = uid
            self.wantedName = deviceName
            self.wantedChannel = max(1, channel)
            if self.running { self.reconcile(reason: "settings") }
        }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.watcher = AudioDeviceWatcher(queue: self.queue) { [weak self] change in
                self?.deviceChanged(change)
            }
            self.reconcile(reason: "start")
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(500))
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            self.timer = t
        }
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            timer?.cancel()
            timer = nil
            watcher = nil
            if input.isRunning {
                input.stop()
                log.info(.audio, "audio.stopped", "Audio input stopped")
            }
            snap.audioStatus = .stopped
            publish()
        }
    }

    // MARK: Device handling

    private func deviceChanged(_ change: AudioDeviceWatcher.Change) {
        switch change {
        case .deviceList: reconcile(reason: "device list changed")
        case .defaultInput: if wantedUID == nil { reconcile(reason: "default input changed") }
        case .sampleRate(let id):
            let rate = AudioDevices.nominalSampleRate(id) ?? 0
            log.info(.audio, "audio.sample_rate_changed", "Device sample rate changed to \(Int(rate)) Hz",
                     ["sample_rate": .double(rate), "previous": .double(input.info?.sampleRate ?? 0)])
            reconcile(reason: "sample rate changed")
        case .deviceDied: reconcile(reason: "device died")
        }
    }

    /// Make the running input match what is wanted and what is plugged in.
    private func reconcile(reason: String) {
        let target: AudioInputDevice?
        if let uid = wantedUID {
            target = AudioDevices.device(uid: uid)
        } else {
            target = AudioDevices.defaultInputDeviceID().flatMap { AudioDevices.device(id: $0) }
        }

        guard let device = target, AudioDevices.isAlive(device.deviceID) else {
            if input.isRunning || snap.audioStatus == .running {
                let name = input.info?.deviceName ?? wantedName ?? "input device"
                input.stop()
                watcher?.watchDevice(nil)
                log.warning(.audio, "audio.disconnected", "Audio device disconnected: \(name)",
                            ["device": .string(name), "reason": .string(reason)])
            }
            let name = wantedName ?? (wantedUID == nil ? "default input" : "input device")
            if snap.audioStatus != .waitingForDevice(name) {
                snap.audioStatus = .waitingForDevice(name)
                if !input.isRunning, reason == "start" {
                    log.warning(.audio, "audio.waiting", "Waiting for audio device: \(name)", ["device": .string(name)])
                }
            }
            publish()
            return
        }

        if let info = input.info, input.isRunning,
           info.deviceID == device.deviceID, info.channel == wantedChannel,
           abs(info.sampleRate - (AudioDevices.nominalSampleRate(device.deviceID) ?? info.sampleRate)) < 0.5 {
            return // already running as wanted
        }

        let wasWaiting: Bool
        if case .waitingForDevice = snap.audioStatus { wasWaiting = true } else { wasWaiting = false }
        let wasRunning = input.isRunning
        let channel = wantedChannel
        do {
            try input.start(device: device, channel: channel)
            watcher?.watchDevice(device.deviceID)
            guard let info = input.info else { return }
            let fields: LogFields = [
                "device": .string(info.deviceName), "uid": .string(info.deviceUID),
                "channel": .int(info.channel), "sample_rate": .double(info.sampleRate),
                "buffer_frames": info.bufferFrames.map { .int($0) } ?? .null,
                "reason": .string(reason),
            ]
            if wasWaiting && reason != "start" {
                log.info(.audio, "audio.reconnected", "Audio device reconnected: \(info.deviceName)", fields)
            } else {
                log.info(.audio, wasRunning ? "audio.restarted" : "audio.started",
                         "Listening to \(info.deviceName) channel \(info.channel) at \(Int(info.sampleRate)) Hz", fields)
            }
            lastRTStats = tc_rt_stats_t()
            snap.audioStatus = .running
            snap.input = info
        } catch {
            let msg = "\(error)"
            log.error(.audio, "audio.start_failed", "Could not start audio input: \(msg)",
                      ["device": .string(device.name), "channel": .int(channel), "error": .string(msg)])
            snap.audioStatus = .error(msg)
            snap.input = nil
        }
        publish()
    }

    // MARK: Polling

    private func poll() {
        let now = HostClock.now()
        while let frame = input.popFrame() {
            handle(core.ingest(frame, now: now))
            ltcLevelSum += frame.volumeDb
            ltcLevelCount += 1
            snap.ltcLevelDb = frame.volumeDb
        }
        handle(core.tick(now: now))
        updateNextCue(now: now)

        // Meter: instant attack, ~24 dB/s fall-off.
        let peak = Double(input.takePeak())
        let peakDb = peak > 0 ? 20 * log10(peak) : -120
        let dt = lastPoll == 0 ? 0 : HostClock.seconds(from: lastPoll, to: now)
        levelDb = max(peakDb, levelDb - 24 * dt, -120)
        lastPoll = now

        if HostClock.seconds(from: lastSecond, to: now) >= 1 {
            lastSecond = now
            everySecond()
        }

        snap.inputLevelDb = levelDb
        snap.lockState = tracker.state
        snap.rate = tracker.rate
        snap.rateProvisional = tracker.rateProvisional
        snap.stats = tracker.stats
        if let f = tracker.lastFrame {
            snap.timecode = f.timecode
            snap.dropFrame = f.dropFrameFlag
        }
        if tracker.state == .noSignal { snap.ltcLevelDb = nil }
        publish()
    }

    private func handle(_ out: TriggerCore.Output) {
        for e in out.ltcEvents { logEvent(e) }
        perform(out.actions)
    }

    private func perform(_ actions: [CueAction]) {
        let now = HostClock.now()
        for a in actions {
            switch a {
            case let .schedule(cue, at, cueFrameTime, via, lateFrames, isUpdate):
                scheduler.schedule(cue, at: at, via: via, lateFrames: lateFrames, cueFrameTime: cueFrameTime)
                let lead = HostClock.seconds(from: now, to: at)
                let fields: LogFields = cue.logFields.merging([
                    "via": .string(via.rawValue), "late_frames": .int(lateFrames),
                    "fire_in_ms": .double(lead * 1000), "offset_ms": .double(core.cues.config.offset * 1000),
                ]) { a, _ in a }
                if isUpdate {
                    log.debug(.cue, "cue.rescheduled", "Refined fire time for \(cue.name)", fields)
                } else {
                    log.debug(.cue, "cue.scheduled", "Scheduled \(cue.name) in \(String(format: "%.0f", lead * 1000)) ms (\(via.rawValue))", fields)
                }
            case let .cancel(cue, reason):
                if scheduler.cancel(cue.id) {
                    log.warning(.cue, "cue.cancelled", "Cancelled \(cue.name): \(reason)",
                                cue.logFields.merging(["reason": .string(reason)]) { a, _ in a })
                }
            case let .missed(cue, reason, heard):
                log.error(.cue, "cue.missed", "MISSED \(cue.name) at \(cue.timecode): \(reason)",
                          cue.logFields.merging(["reason": .string(reason), "heard_tc": .string(heard.description),
                                                 "armed": .bool(snap.armed)]) { a, _ in a })
            case let .timingCheck(cue, predicted, actual):
                let err = HostClock.seconds(from: predicted, to: actual)
                log.debug(.cue, "cue.timing_check", "Cue frame arrived \(String(format: "%+.2f", err * 1000)) ms from prediction",
                          ["cue": .string(cue.name), "prediction_error_ms": .double(err * 1000)])
            }
        }
    }

    private func handleReport(_ r: FireReport) {
        if r.kind != .test {
            core.cues.markFired(r.cue.id)
            lastFiredCueID = r.cue.id
            snap.lastFireCueIDForNext = r.cue.id
        }
        snap.lastFire = r
        snap.fireCount += 1
        publish()
        guard r.kind != .test else { return }

        let wall = { (t: UInt64) -> String in Self.wallClock(hostTime: t) }
        let errorUs = HostClock.seconds(from: r.target, to: r.sentAt) * 1_000_000
        var fields: LogFields = r.cue.logFields.merging([
            "via": .string(r.via?.rawValue ?? "manual"), "late_frames": .int(r.lateFrames),
            "scheduled_time": .string(wall(r.target)), "sent_time": .string(wall(r.sentAt)),
            "send_error_us": .double(errorUs),
            "lead_ms": .double(HostClock.seconds(from: r.scheduledAt, to: r.target) * 1000),
            "offset_ms": .double(core.cues.config.offset * 1000),
        ]) { a, _ in a }
        if let f = r.cueFrameTime { fields["cue_frame_time"] = .string(wall(f)) }
        let how = r.via == .catchWindow ? "via catch window, \(r.lateFrames) frame\(r.lateFrames == 1 ? "" : "s") late" : "exact"
        switch r.kind {
        case .fired:
            log.info(.cue, "cue.fired", "FIRED \(r.cue.name) at \(r.cue.timecode) (\(how), sent \(String(format: "%+.0f", errorUs)) µs from schedule)", fields)
        case .manual:
            log.info(.cue, "cue.fired_manual", "FIRED \(r.cue.name) manually (Fire Next Cue)", fields)
        case .wouldHaveFired:
            log.info(.cue, "cue.would_fire", "Would have fired \(r.cue.name) at \(r.cue.timecode) (\(how)) — disarmed", fields)
        case .test:
            break
        }
    }

    /// Converts a host time to local wall-clock text with microseconds.
    static func wallClock(hostTime: UInt64) -> String {
        let date = Date().addingTimeInterval(HostClock.seconds(from: HostClock.now(), to: hostTime))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSSSSS"
        return f.string(from: date)
    }

    private func updateNextCue(now: UInt64) {
        let enabled = allCues.filter(\.enabled).sorted { $0.timecode < $1.timecode }
        var next: Cue?
        var countdown: Double?
        if tracker.isLocked, let rate = tracker.rate, let index = tracker.lastLockedIndex {
            next = enabled.first { c in
                let ci = c.timecode.frameIndex(at: rate)
                return ci >= index - core.cues.config.catchWindow && !core.cues.isDone(c.id)
                    || (ci >= index && core.cues.isScheduled(c.id))
            }
            if let n = next, let t = core.predictedFireTime(of: n) {
                countdown = max(0, HostClock.seconds(from: now, to: t))
            }
        } else if let last = lastFiredCueID, let lastCue = allCues.first(where: { $0.id == last }) {
            next = enabled.first { $0.timecode > lastCue.timecode } ?? enabled.first
        } else {
            next = enabled.first
        }
        snap.nextCue = next
        snap.nextCueCountdown = countdown
    }

    private func logEvent(_ e: LTCEvent) {
        switch e {
        case .segmentStarted(let tc):
            log.info(.ltc, "ltc.segment_start", "LTC heard from \(tc)", ["tc": .string("\(tc)")])
        case let .segmentEnded(start, end, duration, frames):
            log.info(.ltc, "ltc.segment", "LTC segment \(start) → \(end) (\(String(format: "%.1f", duration)) s)",
                     ["start": .string("\(start)"), "end": .string("\(end)"),
                      "duration_s": .double(duration), "frames": .int(frames)])
        case let .locked(tc, rate, provisional, quick):
            log.info(.ltc, "ltc.lock", "Locked at \(tc), \(rate.displayName)\(provisional ? " (confirming 29.97/30)" : "")",
                     ["tc": .string("\(tc)"), "rate": .string(rate.rawValue), "provisional": .bool(provisional),
                      "quick_relock": .bool(quick), "ltc_level_db": snap.ltcLevelDb.map { .double($0) } ?? .null])
        case let .unlocked(tc, reason, lockedFor):
            log.info(.ltc, "ltc.unlock", "Lock lost at \(tc): \(reason.rawValue)",
                     ["tc": .string("\(tc)"), "reason": .string(reason.rawValue), "locked_for_s": .double(lockedFor)])
        case let .rateRefined(rate, fps):
            log.info(.ltc, "ltc.rate", "Frame rate measured as \(rate.displayName) (\(String(format: "%.3f", fps)) fps)",
                     ["rate": .string(rate.rawValue), "measured_fps": .double(fps)])
        }
    }

    /// Once-a-second housekeeping: verbose statistics and audio-thread warnings.
    private func everySecond() {
        if ltcLevelCount > 0 {
            log.debug(.ltc, "ltc.level", "LTC level \(String(format: "%.1f", ltcLevelSum / Double(ltcLevelCount))) dBFS",
                      ["ltc_level_db": .double(ltcLevelSum / Double(ltcLevelCount)),
                       "input_peak_db": .double(levelDb),
                       "frames": .int(tracker.stats.frames),
                       "out_of_sequence": .int(tracker.stats.outOfSequence),
                       "dropped": .int(tracker.stats.droppedFrames),
                       "lock_failures": .int(tracker.stats.lockFailures),
                       "jitter_ms": tracker.model.lastResidual.map { .double($0 * 1000) } ?? .null,
                       "period_ms": tracker.model.period.map { .double($0 * 1000) } ?? .null])
            ltcLevelSum = 0
            ltcLevelCount = 0
        }
        guard let s = input.stats() else { return }
        let o = lastRTStats
        if s.render_errors > o.render_errors || s.ring_overflows > o.ring_overflows || s.oversize_buffers > o.oversize_buffers {
            log.warning(.audio, "audio.rt_problem", "Audio thread reported problems",
                        ["render_errors": .int(Int(s.render_errors - o.render_errors)),
                         "ring_overflows": .int(Int(s.ring_overflows - o.ring_overflows)),
                         "oversize_buffers": .int(Int(s.oversize_buffers - o.oversize_buffers))])
        }
        if s.discontinuities > o.discontinuities || s.invalid_frames > o.invalid_frames
            || s.stale_frames > o.stale_frames {
            log.debug(.audio, "audio.stats", "Audio input statistics",
                      ["discontinuities": .int(Int(s.discontinuities - o.discontinuities)),
                       "invalid_frames": .int(Int(s.invalid_frames - o.invalid_frames)),
                       "stale_frames": .int(Int(s.stale_frames - o.stale_frames)),
                       "buffer_frames": .int(Int(s.last_buffer_frames))])
        }
        lastRTStats = s
    }

    private func publish() {
        let s = snap
        snapshotLock.withLock { $0 = s }
    }
}
