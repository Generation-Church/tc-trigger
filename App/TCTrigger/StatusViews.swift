import SwiftUI
import TCTriggerKit

/// Big timecode readout. Dimmed unless locked.
struct TimecodeDisplay: View {
    let snapshot: EngineSnapshot
    var size: CGFloat = 56

    var body: some View {
        let text = snapshot.timecode?.formatted(dropFrame: snapshot.dropFrame) ?? "--:--:--:--"
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .foregroundStyle(snapshot.lockState == .locked ? Color.primary : Color.secondary.opacity(0.6))
            .contentTransition(.identity)
            .accessibilityLabel("Timecode \(text)")
    }
}

struct LockBadge: View {
    let state: LockState

    var body: some View {
        Text(state.rawValue.uppercased())
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case .locked: return .blue
        case .acquiring: return .orange
        case .noSignal: return .secondary
        }
    }
}

/// Horizontal peak meter from -60 to 0 dBFS.
struct LevelMeter: View {
    let db: Double

    var body: some View {
        GeometryReader { geo in
            let fraction = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red],
                                         startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: geo.size.width * fraction)
                    }
            }
        }
        .frame(height: 8)
    }
}

extension EngineSnapshot {
    var rateText: String {
        guard let rate else { return "—" }
        return rateProvisional ? "30 fps (confirming 29.97/30…)" : rate.displayName
    }

    var inputText: String {
        guard let i = input, audioStatus == .running else { return audioStatus.label }
        var s = "\(i.deviceName) · ch \(i.channel) · \(Int(i.sampleRate)) Hz"
        if let b = i.bufferFrames { s += " · \(b)-sample buffer" }
        return s
    }
}

/// The main status panel, shared by the window and (in compact form) the menu-bar panel.
struct StatusPanel: View {
    @EnvironmentObject var model: AppModel
    var compact = false

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            HStack {
                Text(model.settings.campusName.isEmpty ? "Campus not set" : model.settings.campusName)
                    .font(compact ? .headline : .title2.weight(.semibold))
                Spacer()
                LockBadge(state: s.lockState)
            }

            TimecodeDisplay(snapshot: s, size: compact ? 34 : 60)
                .frame(maxWidth: .infinity, alignment: .center)

            ArmButton(compact: compact)
            ManualButtons(compact: compact)
            NextCueLine()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Frame rate").foregroundStyle(.secondary)
                    Text(s.rateText)
                }
                GridRow {
                    Text("Input level").foregroundStyle(.secondary)
                    HStack {
                        LevelMeter(db: s.inputLevelDb)
                        Text(s.inputLevelDb > -100 ? String(format: "%.0f dB", s.inputLevelDb) : "—")
                            .monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                if let ltc = s.ltcLevelDb {
                    GridRow {
                        Text("LTC level").foregroundStyle(.secondary)
                        Text(String(format: "%.1f dBFS", ltc)).monospacedDigit()
                    }
                }
                GridRow {
                    Text("Audio").foregroundStyle(.secondary)
                    Text(s.inputText)
                        .foregroundStyle(s.audioStatus == .running ? Color.primary : Color.orange)
                        .lineLimit(2)
                }
            }
            .font(compact ? .callout : .body)

            if model.micPermission != .authorized {
                MicPermissionBanner()
            }
        }
    }
}

/// Big Arm / Disarm control.
struct ArmButton: View {
    @EnvironmentObject var model: AppModel
    var compact = false

    var body: some View {
        let armed = model.snapshot.armed
        Button {
            model.setArmed(!armed)
        } label: {
            HStack {
                Image(systemName: armed ? "bolt.fill" : "bolt.slash")
                Text(armed ? "ARMED — cues will send MIDI" : "DISARMED — cues are only logged")
                    .fontWeight(.bold)
                Spacer()
                Text(armed ? "Disarm" : "Arm").font(.callout)
            }
            .padding(.vertical, compact ? 6 : 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .foregroundStyle(armed ? Color.white : Color.primary)
            .background(armed ? Color.green : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(armed ? "Click to disarm" : "Click to arm")
    }
}

/// "Next: Song 2 at 01:00:00:00 — in 4.2 s", plus the last fire.
struct NextCueLine: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.snapshot
        VStack(alignment: .leading, spacing: 4) {
            if let next = s.nextCue {
                HStack {
                    Text("Next").foregroundStyle(.secondary)
                    Text(next.name).fontWeight(.semibold)
                    Text(next.timecode.description).monospaced().foregroundStyle(.secondary)
                    Spacer()
                    if let t = s.nextCueCountdown, t < 600 {
                        Text(t < 10 ? String(format: "in %.1f s", t) : String(format: "in %d:%02d", Int(t) / 60, Int(t) % 60))
                            .monospacedDigit().fontWeight(.bold)
                            .foregroundStyle(t < 10 ? Color.orange : Color.primary)
                    }
                }
            } else {
                Text(model.cues.isEmpty ? "No cues yet — add them in the Cues tab." : "No enabled cues.")
                    .foregroundStyle(.secondary)
            }
            if let f = s.lastFire {
                HStack {
                    Image(systemName: f.kind == .fired || f.kind == .manual ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(f.kind == .fired || f.kind == .manual ? Color.green : Color.secondary)
                    Text(lastFireText(f)).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func lastFireText(_ f: FireReport) -> String {
        let ago = HostClock.seconds(from: f.sentAt, to: HostClock.now())
        let when = ago < 90 ? "\(Int(ago)) s ago" : "\(Int(ago / 60)) min ago"
        switch f.kind {
        case .fired:
            let how = f.via == .catchWindow ? " (catch window, \(f.lateFrames) late)" : ""
            return "Fired \(f.cue.name)\(how), \(when)"
        case .wouldHaveFired: return "Would have fired \(f.cue.name) (disarmed), \(when)"
        case .test: return "Test fired \(f.cue.name), \(when)"
        case .manual: return "Fired \(f.cue.name) manually (Fire Next), \(when)"
        }
    }
}

struct MicPermissionBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "mic.slash.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 6) {
                Text("TC Trigger needs audio input access to hear LTC.")
                    .font(.callout.weight(.semibold))
                HStack {
                    if model.micPermission == .notDetermined {
                        Button("Allow Audio Input…") { model.requestMicrophoneAccess() }
                    } else {
                        Text("Turn on TC Trigger in Privacy & Security → Microphone, then quit and reopen TC Trigger.")
                            .font(.callout)
                        Button("Open Settings") { model.openMicrophonePrivacySettings() }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
