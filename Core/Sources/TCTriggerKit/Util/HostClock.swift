import Darwin

/// Converts between mach host time ticks (the clock Core Audio and CoreMIDI use) and seconds.
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    public static var ticksPerSecond: Double {
        1.0e9 * Double(timebase.denom) / Double(timebase.numer)
    }

    public static func now() -> UInt64 { mach_absolute_time() }

    public static func seconds(_ ticks: UInt64) -> Double { Double(ticks) / ticksPerSecond }

    /// Signed difference `a - b` in seconds.
    public static func seconds(from b: UInt64, to a: UInt64) -> Double {
        a >= b ? Double(a - b) / ticksPerSecond : -Double(b - a) / ticksPerSecond
    }

    public static func ticks(_ seconds: Double) -> Int64 { Int64((seconds * ticksPerSecond).rounded()) }

    public static func adding(_ seconds: Double, to t: UInt64) -> UInt64 {
        let d = ticks(seconds)
        return d >= 0 ? t &+ UInt64(d) : t &- UInt64(-d)
    }
}
