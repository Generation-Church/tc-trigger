import Foundation

/// The frame rates TC Trigger recognises.
public enum FrameRate: String, Codable, CaseIterable, Sendable {
    case fps24 = "24"
    case fps25 = "25"
    case fps2997DF = "29.97DF"
    case fps2997NDF = "29.97NDF"
    case fps30 = "30"

    /// Frames per second as counted in the timecode (24, 25 or 30).
    public var nominal: Int {
        switch self {
        case .fps24: return 24
        case .fps25: return 25
        case .fps2997DF, .fps2997NDF, .fps30: return 30
        }
    }

    /// Real frames per second.
    public var exact: Double {
        switch self {
        case .fps24: return 24
        case .fps25: return 25
        case .fps2997DF, .fps2997NDF: return 30000.0 / 1001.0
        case .fps30: return 30
        }
    }

    public var isDropFrame: Bool { self == .fps2997DF }

    public var displayName: String {
        switch self {
        case .fps24: return "24 fps"
        case .fps25: return "25 fps"
        case .fps2997DF: return "29.97 DF"
        case .fps2997NDF: return "29.97 NDF"
        case .fps30: return "30 fps"
        }
    }
}

/// An SMPTE timecode value (HH:MM:SS:FF).
public struct Timecode: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int

    public init(_ hours: Int, _ minutes: Int, _ seconds: Int, _ frames: Int) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    /// Parses "HH:MM:SS:FF" (";" or "." also accepted as the last separator).
    public init?(string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })
        guard parts.count == 4,
              let h = Int(parts[0]), let m = Int(parts[1]),
              let s = Int(parts[2]), let f = Int(parts[3]),
              (0..<24).contains(h), (0..<60).contains(m), (0..<60).contains(s), (0..<30).contains(f)
        else { return nil }
        self.init(h, m, s, f)
    }

    public var description: String {
        String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }

    public static func < (a: Timecode, b: Timecode) -> Bool {
        (a.hours, a.minutes, a.seconds, a.frames) < (b.hours, b.minutes, b.seconds, b.frames)
    }

    /// Whether this label can exist at the given rate (drop-frame skips frames 0 and 1
    /// at the start of every minute except every tenth).
    public func isValid(at rate: FrameRate) -> Bool {
        guard frames < rate.nominal else { return false }
        if rate.isDropFrame, seconds == 0, frames < 2, minutes % 10 != 0 { return false }
        return true
    }

    /// Frames elapsed since 00:00:00:00, counting only frames that actually exist.
    public func frameIndex(nominal fps: Int, dropFrame: Bool) -> Int {
        let totalMinutes = hours * 60 + minutes
        var index = ((totalMinutes * 60) + seconds) * fps + frames
        if dropFrame {
            // Two labels are skipped per minute, except every tenth minute.
            index -= 2 * (totalMinutes - totalMinutes / 10)
        }
        return index
    }

    public func frameIndex(at rate: FrameRate) -> Int {
        frameIndex(nominal: rate.nominal, dropFrame: rate.isDropFrame)
    }

    /// The timecode label for a frame index (inverse of frameIndex).
    public init(frameIndex: Int, nominal fps: Int, dropFrame: Bool) {
        var idx = frameIndex
        let framesPerDay = dropFrame ? 2_589_408 : 24 * 3600 * fps
        idx = ((idx % framesPerDay) + framesPerDay) % framesPerDay
        if dropFrame {
            let per10Min = 17982 // frames in 10 minutes at 29.97 DF
            let perMin = 1798 // frames in a dropped minute
            let tens = idx / per10Min
            let rem = idx % per10Min
            var extra = 18 * tens
            if rem > 1 { extra += 2 * ((rem - 2) / perMin) }
            idx += extra
        }
        let f = idx % fps
        let totalSeconds = idx / fps
        self.init(totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, f)
    }

    public init(frameIndex: Int, rate: FrameRate) {
        self.init(frameIndex: frameIndex, nominal: rate.nominal, dropFrame: rate.isDropFrame)
    }

    /// Display string; drop-frame uses ";" before the frames by convention.
    public func formatted(dropFrame: Bool) -> String {
        String(format: dropFrame ? "%02d:%02d:%02d;%02d" : "%02d:%02d:%02d:%02d",
               hours, minutes, seconds, frames)
    }
}
