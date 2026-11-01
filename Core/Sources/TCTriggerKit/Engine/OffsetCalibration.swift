import Foundation

/// Offset calibration with a loopback cable: Ableton's output → a spare input on the same
/// interface. When a cue fires, TC Trigger listens on that input for the test clip's click and
/// measures how long after the cue frame it arrived. Both are timestamped on the same clock,
/// and both pass through the same input converters, so the difference is exactly how late
/// Ableton's sound leaves the interface relative to the LTC cue frame arriving.
public enum OffsetCalibration {
    public struct Measurement: Equatable, Sendable, Identifiable {
        public var id: UInt64 { clickTime }
        public let cueName: String
        /// Click arrival minus cue-frame start, in ms (positive = Ableton sounded late).
        public let delayMs: Double
        /// The offset that was in effect for this fire.
        public let offsetUsedMs: Double
        /// The offset that would have put the click exactly on the cue frame.
        public let suggestedOffsetMs: Double
        public let clickTime: UInt64
    }

    public static func measure(cueName: String, cueFrameTime: UInt64, clickTime: UInt64, offsetUsedMs: Double) -> Measurement {
        let delay = HostClock.seconds(from: cueFrameTime, to: clickTime) * 1000
        return Measurement(cueName: cueName, delayMs: delay, offsetUsedMs: offsetUsedMs,
                           suggestedOffsetMs: offsetUsedMs - delay, clickTime: clickTime)
    }

    /// Average suggestion, rounded to whole ms and clamped to the allowed range.
    public static func suggestion(_ m: [Measurement]) -> Int? {
        guard !m.isEmpty else { return nil }
        let avg = m.map(\.suggestedOffsetMs).reduce(0, +) / Double(m.count)
        return Int(avg.rounded()).clamped(to: AppSettings.offsetRange)
    }

    /// Spread between measurements (ms); more than a few ms means something is inconsistent.
    public static func spread(_ m: [Measurement]) -> Double {
        guard let lo = m.map(\.delayMs).min(), let hi = m.map(\.delayMs).max() else { return 0 }
        return hi - lo
    }
}

/// Calibration status for the UI.
public struct CalibrationStatus: Equatable, Sendable {
    public var clickChannel: Int?
    public var measurements: [OffsetCalibration.Measurement] = []
    public var waitingForClick = false
    public var lastProblem: String?
    public init() {}
}
