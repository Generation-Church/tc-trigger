// ltcmon — listen to an audio input and print LTC events, without the app.
//
//   ltcmon --list
//   ltcmon --device "MOTU 828" --channel 3 --seconds 30

import Foundation
import TCTriggerKit

setvbuf(stdout, nil, _IOLBF, 0)

var args = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

if args.contains("--list") {
    for d in AudioDevices.inputDevices() {
        print("\(d.name)  [\(d.inputChannels) in, \(Int(d.nominalSampleRate)) Hz]  uid=\(d.uid)")
    }
    exit(0)
}

let deviceName = take("--device")
let channel = Int(take("--channel") ?? "1") ?? 1
let seconds = Double(take("--seconds") ?? "0") ?? 0

var uid: String?
if let deviceName {
    guard let d = AudioDevices.inputDevices().first(where: { $0.name == deviceName || $0.uid == deviceName }) else {
        print("No input device named \(deviceName). Try --list.")
        exit(1)
    }
    uid = d.uid
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltcmon-logs")
let log = EventLog(directory: dir)
log.verbose = true
log.addObserver { e in
    let fields = e.fields.keys.sorted().map { "\($0)=\(e.fields[$0]!)" }.joined(separator: " ")
    print("\(e.level.rawValue.uppercased()) [\(e.category.rawValue)] \(e.message)  \(fields)")
}
let engine = LTCEngine(log: log, midi: nil)
engine.configure(deviceUID: uid, deviceName: deviceName, channel: channel)
engine.start()

let start = Date()
var lastPrinted = ""
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    let s = engine.snapshot()
    let line = "  \(s.timecode?.formatted(dropFrame: s.dropFrame) ?? "--:--:--:--")  \(s.lockState.rawValue)  \(s.rateText)  input \(String(format: "%.0f", s.inputLevelDb)) dB"
    if line != lastPrinted { print(line); lastPrinted = line }
    if seconds > 0, Date().timeIntervalSince(start) > seconds {
        engine.stop()
        log.flush()
        exit(0)
    }
}
RunLoop.main.run()

extension EngineSnapshot {
    var rateText: String {
        guard let rate else { return "" }
        return rateProvisional ? "30 (confirming)" : rate.displayName
    }
}
