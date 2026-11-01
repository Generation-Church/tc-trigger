// ltcgen — make LTC test WAV files.
//
// Examples:
//   ltcgen --fps 25 --cue 01:00:00:00 --preroll 5 --length 20 --out song2_25.wav
//   ltcgen --fps 29.97df --start 00:59:58:00 --length 10 --dropout 01:00:00:00x2 --out glitch.wav

import Foundation
import TCTriggerKit

func usage() -> Never {
    print("""
    Usage: ltcgen --fps <24|25|29.97df|29.97ndf|30> --out <file.wav> [options]

      --start HH:MM:SS:FF     first frame of LTC (default 01:00:00:00)
      --cue HH:MM:SS:FF       alternative to --start: the cue frame; LTC starts --preroll seconds earlier
      --preroll SECONDS       LTC before the cue (with --cue; default 5)
      --length SECONDS        seconds of LTC (default 20)
      --lead SECONDS          silence before the LTC (default 2)
      --tail SECONDS          silence after the LTC (default 2)
      --rate HZ               sample rate (default 48000)
      --level DBFS            LTC level (default -12)
      --dropout HH:MM:SS:FFxN silence N frames starting at that timecode (repeatable)
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

let rateNames: [String: FrameRate] = ["24": .fps24, "25": .fps25, "29.97df": .fps2997DF,
                                     "29.97ndf": .fps2997NDF, "30": .fps30]
guard let fpsArg = take("--fps"), let rate = rateNames[fpsArg.lowercased()],
      let out = take("--out") else { usage() }

let sampleRate = Double(take("--rate") ?? "48000") ?? 48000
let length = Double(take("--length") ?? "20") ?? 20
let frameCount = Int((length * rate.exact).rounded())
var start = Timecode(1, 0, 0, 0)
var cue: Timecode?
if let c = take("--cue") {
    guard let t = Timecode(string: c) else { usage() }
    cue = t
    let preroll = Double(take("--preroll") ?? "5") ?? 5
    start = Timecode(frameIndex: t.frameIndex(at: rate) - Int((preroll * rate.exact).rounded()), rate: rate)
} else if let s = take("--start") {
    guard let t = Timecode(string: s) else { usage() }
    start = t
}

var opts = LTCGenerator.Options(rate: rate, start: start, frameCount: frameCount)
opts.sampleRate = sampleRate
opts.levelDb = Double(take("--level") ?? "-12") ?? -12
opts.leadSilence = Double(take("--lead") ?? "2") ?? 2
opts.tailSilence = Double(take("--tail") ?? "2") ?? 2
while let d = take("--dropout") {
    let parts = d.split(separator: "x")
    guard parts.count == 2, let t = Timecode(string: String(parts[0])), let n = Int(parts[1]) else { usage() }
    opts.dropouts.append((t, n))
}
if !args.isEmpty { print("Unknown arguments: \(args)"); usage() }

let result = LTCGenerator.render(opts)
let url = URL(fileURLWithPath: out)
do {
    try WAVWriter.write(result.samples, sampleRate: Int(sampleRate), to: url)
} catch {
    print("Could not write \(out): \(error)")
    exit(1)
}
let end = Timecode(frameIndex: start.frameIndex(at: rate) + frameCount - 1, rate: rate)
print("Wrote \(out): \(rate.displayName), \(start.formatted(dropFrame: rate.isDropFrame)) → \(end.formatted(dropFrame: rate.isDropFrame)), \(String(format: "%.1f", Double(result.samples.count) / sampleRate)) s")
if let cue, let pos = result.frameStarts[cue] {
    print("  cue \(cue.formatted(dropFrame: rate.isDropFrame)) starts at sample \(pos) (\(String(format: "%.4f", Double(pos) / sampleRate)) s into the file)")
}
