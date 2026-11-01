import CTCCore
import Foundation

/// Makes LTC audio with libltc's encoder, for test files and unit tests.
public struct LTCGenerator {
    public struct Options {
        public var rate: FrameRate
        public var start: Timecode
        public var frameCount: Int
        public var sampleRate: Double = 48000
        public var levelDb: Double = -12
        public var leadSilence: Double = 0
        public var tailSilence: Double = 0
        /// Frames to replace with silence (simulates a codec glitch): (first timecode, count).
        public var dropouts: [(Timecode, Int)] = []

        public init(rate: FrameRate, start: Timecode, frameCount: Int) {
            self.rate = rate
            self.start = start
            self.frameCount = frameCount
        }
    }

    public struct Output {
        public var samples: [Float]
        /// Sample index where each generated frame starts, keyed by timecode.
        public var frameStarts: [Timecode: Int]
        public var sampleRate: Double
    }

    public static func render(_ o: Options) -> Output {
        let standard: LTC_TV_STANDARD
        switch o.rate {
        case .fps24: standard = LTC_TV_FILM_24
        case .fps25: standard = LTC_TV_625_50
        default: standard = LTC_TV_525_60
        }
        guard let enc = ltc_encoder_create(o.sampleRate, o.rate.exact, standard, 0) else {
            return Output(samples: [], frameStarts: [:], sampleRate: o.sampleRate)
        }
        defer { ltc_encoder_free(enc) }
        ltc_encoder_set_volume(enc, o.levelDb)

        // libltc sets the drop-frame bit for any 29.97; clear it for non-drop.
        var frame = LTCFrame()
        ltc_encoder_get_frame(enc, &frame)
        frame.dfbit = o.rate.isDropFrame ? 1 : 0
        ltc_encoder_set_frame(enc, &frame)

        var tc = SMPTETimecode()
        tc.hours = UInt8(o.start.hours)
        tc.mins = UInt8(o.start.minutes)
        tc.secs = UInt8(o.start.seconds)
        tc.frame = UInt8(o.start.frames)
        ltc_encoder_set_timecode(enc, &tc)

        let silenceFrames = Set(o.dropouts.flatMap { start, count -> [Int] in
            let i = start.frameIndex(at: o.rate)
            return Array(i..<(i + count))
        })

        var samples = [Float](repeating: 0, count: Int(o.leadSilence * o.sampleRate))
        var starts: [Timecode: Int] = [:]
        var buf = [ltcsnd_sample_t](repeating: 128, count: Int(ltc_encoder_get_buffersize(enc)))
        var index = o.start.frameIndex(at: o.rate)
        for _ in 0..<o.frameCount {
            let label = Timecode(frameIndex: index, rate: o.rate)
            starts[label] = samples.count
            ltc_encoder_encode_frame(enc)
            let n = Int(ltc_encoder_copy_buffer(enc, &buf))
            let mute = silenceFrames.contains(index)
            for i in 0..<n {
                samples.append(mute ? 0 : (Float(buf[i]) - 128) / 127)
            }
            ltc_encoder_inc_timecode(enc)
            index += 1
        }
        samples += [Float](repeating: 0, count: Int(o.tailSilence * o.sampleRate))
        return Output(samples: samples, frameStarts: starts, sampleRate: o.sampleRate)
    }
}

/// Writes 16-bit PCM WAV files (mono, or stereo when `right` is given).
public enum WAVWriter {
    public static func write(_ samples: [Float], right: [Float]? = nil, sampleRate: Int, to url: URL) throws {
        let channels = right == nil ? 1 : 2
        var interleaved = samples
        if let right {
            interleaved = []
            interleaved.reserveCapacity(samples.count * 2)
            for i in 0..<samples.count {
                interleaved.append(samples[i])
                interleaved.append(i < right.count ? right[i] : 0)
            }
        }
        try writeInterleaved(interleaved, channels: channels, sampleRate: sampleRate, to: url)
    }

    static func writeInterleaved(_ samples: [Float], channels: Int, sampleRate: Int, to url: URL) throws {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2 * channels)); u16(UInt16(2 * channels)); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        data.reserveCapacity(data.count + samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }
}
