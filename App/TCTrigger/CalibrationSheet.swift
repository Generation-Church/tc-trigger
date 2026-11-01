import SwiftUI
import TCTriggerKit

/// Measures the right offset with a loopback cable and a click in Ableton.
struct CalibrationSheet: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var clickChannel = 2
    @State private var running = false

    var body: some View {
        let cal = model.snapshot.calibration
        VStack(alignment: .leading, spacing: 12) {
            Text("Measure the offset").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Run a short cable from a spare **output** on this interface into a spare **input**.")
                Text("2. In Ableton, make a test scene whose clip starts with a sharp click right at its start, on a track routed to that spare output. Map it to a cue and set its launch quantization to None.")
                Text("3. Choose the spare input below, click **Start**, **arm** TC Trigger, and play an LTC test file (or the real LTC) through the cue 3–5 times.")
                Text("Each fire measures how late Ableton's click comes out compared with the cue frame. Apply the suggested offset, then test once more: it should read close to 0 ms.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Picker("Loopback input", selection: $clickChannel) {
                    ForEach(1...max(2, model.selectedDevice?.inputChannels ?? 2), id: \.self) { ch in
                        Text("Input \(ch)").tag(ch)
                    }
                }
                .frame(width: 220)
                .disabled(running)
                Spacer()
                Button(running ? "Stop" : "Start") {
                    if running { model.stopCalibration() } else { model.startCalibration(clickChannel: clickChannel) }
                    running.toggle()
                }
                .disabled(!running && clickChannel == model.settings.audioChannel)
            }
            if clickChannel == model.settings.audioChannel {
                Text("That's the LTC input. Choose the input the loopback cable is plugged into.").font(.caption).foregroundStyle(.orange)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    if cal.measurements.isEmpty {
                        Text(running ? (cal.waitingForClick ? "Listening for the click…" : "Waiting for a cue to fire…") : "No measurements yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(cal.measurements.enumerated()), id: \.offset) { i, m in
                        HStack {
                            Text("\(i + 1). \(m.cueName)")
                            Spacer()
                            Text(String(format: "click %+.1f ms (offset was %+.0f) → suggests %+.0f ms", m.delayMs, m.offsetUsedMs, m.suggestedOffsetMs))
                                .monospacedDigit()
                        }
                        .font(.callout)
                    }
                    if let p = cal.lastProblem { Text(p).foregroundStyle(.red).font(.callout) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if let s = OffsetCalibration.suggestion(cal.measurements) {
                    let spread = OffsetCalibration.spread(cal.measurements)
                    Text("Suggested offset: \(s > 0 ? "+" : "")\(s) ms").font(.headline)
                    if cal.measurements.count > 1 {
                        Text(String(format: "(spread %.1f ms%@)", spread, spread > 5 ? " — inconsistent, measure again" : ""))
                            .font(.caption).foregroundStyle(spread > 5 ? .orange : .secondary)
                    }
                    Spacer()
                    Button("Apply \(s > 0 ? "+" : "")\(s) ms") { model.applyCalibratedOffset(s) }
                } else {
                    Text("Current offset: \(model.settings.offsetMs) ms").foregroundStyle(.secondary)
                    Spacer()
                }
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onDisappear { if running { model.stopCalibration() } }
    }

    private func close() {
        if running { model.stopCalibration() }
        running = false
        isPresented = false
    }
}
