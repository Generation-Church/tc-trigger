import CTCCore

/// One LTC frame as heard by the decoder, with the exact host time at which it started.
public struct DecodedFrame: Equatable, Sendable {
    public var timecode: Timecode
    public var dropFrameFlag: Bool
    public var reverse: Bool
    /// mach host time of the start of this frame.
    public var hostTime: UInt64
    /// Stream sample index of the start of this frame.
    public var sampleStart: Int64
    /// LTC signal level in dBFS, as measured by libltc.
    public var volumeDb: Double

    public init(timecode: Timecode, dropFrameFlag: Bool = false, reverse: Bool = false,
                hostTime: UInt64, sampleStart: Int64 = 0, volumeDb: Double = -12) {
        self.timecode = timecode
        self.dropFrameFlag = dropFrameFlag
        self.reverse = reverse
        self.hostTime = hostTime
        self.sampleStart = sampleStart
        self.volumeDb = volumeDb
    }

    init(_ f: tc_frame_t) {
        self.init(timecode: Timecode(Int(f.hours), Int(f.minutes), Int(f.seconds), Int(f.frames)),
                  dropFrameFlag: f.drop_frame != 0,
                  reverse: f.reverse != 0,
                  hostTime: f.host_time_start,
                  sampleStart: f.sample_start,
                  volumeDb: f.volume_db)
    }
}
