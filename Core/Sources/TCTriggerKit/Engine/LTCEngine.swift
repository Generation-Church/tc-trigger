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

    public init() {}
}

/// Owns the audio input and the LTC lock tracker. All work happens on one high-priority
/// serial queue that polls the real-time ring buffer every 2 ms.
public final class LTCEngine: @unchecked Sendable {
    public let queue = DispatchQueue(label: "church.generation.tctrigger.engine", qos: .userInteractive)
    private let log: EventLog
    private let input = AudioInput()
    private let tracker: LockTracker
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

    /// Called on the engine queue for every LTC event (the cue engine hooks in here later).
    public var onLTCEvent: ((LTCEvent) -> Void)?

    public init(log: EventLog, lockConfig: LockTracker.Config = .init()) {
        self.log = log
        self.tracker = LockTracker(config: lockConfig)
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
            handle(tracker.ingest(frame), latest: frame)
            ltcLevelSum += frame.volumeDb
            ltcLevelCount += 1
            snap.ltcLevelDb = frame.volumeDb
        }
        handle(tracker.tick(now: now), latest: nil)

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

    private func handle(_ events: [LTCEvent], latest: DecodedFrame?) {
        for e in events {
            logEvent(e)
            onLTCEvent?(e)
        }
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
