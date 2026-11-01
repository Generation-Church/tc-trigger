import CTCCore
import Testing
@testable import TCTriggerKit

struct CalibrationTests {
    @Test func clickDetectorTimestampsTheFirstLoudSampleAfterArming() {
        let rt = tc_rt_create(48000, 4096, 2)!
        defer { tc_rt_destroy(rt) }
        let tps = tc_rt_ticks_per_sample(rt)
        let base: UInt64 = 5_000_000_000
        var signal = [Float](repeating: 0.001, count: 48000) // quiet noise floor
        signal[1000] = 0.5      // a click before arming time: must be ignored
        signal[30_123] = -0.4   // the real click (negative polarity still counts)
        signal[30_200] = 0.9
        tc_rt_arm_click(rt, base + UInt64(Double(20_000) * tps), 0.1)
        signal.withUnsafeBufferPointer { p in
            var pos = 0
            while pos < p.count {
                let n = min(256, p.count - pos)
                tc_rt_process_click(rt, p.baseAddress! + pos, UInt32(n), base + UInt64((Double(pos) * tps).rounded()))
                pos += n
            }
        }
        let t = tc_rt_click_time(rt)
        let expected = base + UInt64((Double(30_123) * tps).rounded())
        #expect(abs(HostClock.seconds(from: expected, to: t)) < 1.0 / 48000)
    }

    @Test func nothingDetectedUntilArmed() {
        let rt = tc_rt_create(48000, 4096, 2)!
        defer { tc_rt_destroy(rt) }
        let loud = [Float](repeating: 0.9, count: 512)
        loud.withUnsafeBufferPointer { tc_rt_process_click(rt, $0.baseAddress!, 512, 1_000) }
        #expect(tc_rt_click_time(rt) == 0)
    }

    @Test func suggestionMath() {
        let frame: UInt64 = 10_000_000_000
        // Offset 0: click 42 ms late → fire 42 ms earlier.
        let a = OffsetCalibration.measure(cueName: "S", cueFrameTime: frame,
                                          clickTime: HostClock.adding(0.042, to: frame), offsetUsedMs: 0)
        #expect(abs(a.delayMs - 42) < 0.01)
        #expect(abs(a.suggestedOffsetMs + 42) < 0.01)
        // Already at −40: click 2 ms late → −42.
        let b = OffsetCalibration.measure(cueName: "S", cueFrameTime: frame,
                                          clickTime: HostClock.adding(0.002, to: frame), offsetUsedMs: -40)
        #expect(abs(b.suggestedOffsetMs + 42) < 0.01)
        // Early click → later offset.
        let c = OffsetCalibration.measure(cueName: "S", cueFrameTime: frame,
                                          clickTime: HostClock.adding(-0.003, to: frame), offsetUsedMs: -45)
        #expect(abs(c.suggestedOffsetMs + 42) < 0.01)
        #expect(OffsetCalibration.suggestion([a, b, c]) == -42)
        #expect(OffsetCalibration.spread([a, b, c]) > 40)
        #expect(OffsetCalibration.suggestion([]) == nil)
    }
}
