import Testing
@testable import TCTriggerKit

struct TimecodeTests {
    @Test func parseAndFormat() {
        #expect(Timecode(string: "01:02:03:04") == Timecode(1, 2, 3, 4))
        #expect(Timecode(string: "01:02:03;04") == Timecode(1, 2, 3, 4))
        #expect(Timecode(string: "24:00:00:00") == nil)
        #expect(Timecode(string: "1:2:3") == nil)
        #expect(Timecode(1, 2, 3, 4).description == "01:02:03:04")
        #expect(Timecode(1, 2, 3, 4).formatted(dropFrame: true) == "01:02:03;04")
    }

    @Test func nonDropIndex() {
        #expect(Timecode(0, 0, 1, 0).frameIndex(at: .fps25) == 25)
        #expect(Timecode(1, 0, 0, 0).frameIndex(at: .fps24) == 86400)
        #expect(Timecode(0, 1, 0, 0).frameIndex(at: .fps30) == 1800)
    }

    @Test func dropFrameIndex() {
        // 00:01:00;02 is the first label of minute 1 (labels ;00 and ;01 are skipped).
        #expect(Timecode(0, 1, 0, 2).frameIndex(at: .fps2997DF) == 1800)
        #expect(Timecode(0, 10, 0, 0).frameIndex(at: .fps2997DF) == 17982)
        #expect(Timecode(1, 0, 0, 0).frameIndex(at: .fps2997DF) == 107892)
        #expect(!Timecode(0, 1, 0, 0).isValid(at: .fps2997DF))
        #expect(Timecode(0, 10, 0, 0).isValid(at: .fps2997DF))
    }

    @Test(arguments: FrameRate.allCases)
    func roundTrip(rate: FrameRate) {
        for index in stride(from: 0, to: 300_000, by: 7) {
            let tc = Timecode(frameIndex: index, rate: rate)
            #expect(tc.isValid(at: rate))
            #expect(tc.frameIndex(at: rate) == index)
        }
    }

    @Test func dropFrameSequenceSkipsLabels() {
        let a = Timecode(0, 0, 59, 29).frameIndex(at: .fps2997DF)
        #expect(Timecode(frameIndex: a + 1, rate: .fps2997DF) == Timecode(0, 1, 0, 2))
    }
}
