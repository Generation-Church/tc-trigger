import Foundation

/// Things a MIDI controller button can do.
public enum ControlAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case toggleArm, arm, disarm, fireNext, panic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toggleArm: return "Arm/Disarm Toggle"
        case .arm: return "Arm"
        case .disarm: return "Disarm"
        case .fireNext: return "Fire Next Cue"
        case .panic: return "Panic"
        }
    }
}

/// A MIDI channel-voice message (MIDI 1.0 bytes).
public struct MIDIMessage: Equatable, Sendable, CustomStringConvertible {
    public let status: UInt8
    public let data1: UInt8
    public let data2: UInt8

    public init(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        self.status = status
        self.data1 = data1
        self.data2 = data2
    }

    public var kind: UInt8 { status & 0xF0 }
    /// 1–16
    public var channel: Int { Int(status & 0x0F) + 1 }
    public var isNoteOn: Bool { kind == 0x90 && data2 > 0 }
    public var isNoteOff: Bool { kind == 0x80 || (kind == 0x90 && data2 == 0) }
    public var isCC: Bool { kind == 0xB0 }

    public var description: String {
        switch kind {
        case 0x80: return "Note Off \(data1) ch \(channel)"
        case 0x90: return data2 == 0 ? "Note Off \(data1) ch \(channel)" : "Note On \(data1) vel \(data2) ch \(channel)"
        case 0xB0: return "CC \(data1) = \(data2) ch \(channel)"
        default: return String(format: "%02X %02X %02X", status, data1, data2)
        }
    }

    public var hex: String { String(format: "%02X %02X %02X", status, data1, data2) }
}

/// Which control a mapping listens to, and how that control behaves.
public struct MIDITrigger: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable { case note, cc }
    public enum Style: String, Codable, Sendable {
        /// Sends a press and a release (note-on/off, or CC high then low). Fires on the press only.
        case momentary
        /// Sends one message per press (note-on only, a fixed CC value, or a toggling CC).
        /// Fires on every message, at most once per 250 ms.
        case single
    }

    public var kind: Kind
    public var channel: Int // 1–16
    public var number: Int  // note or controller number
    public var style: Style

    public init(kind: Kind, channel: Int, number: Int, style: Style) {
        self.kind = kind
        self.channel = channel
        self.number = number
        self.style = style
    }

    public func matches(_ m: MIDIMessage) -> Bool {
        guard m.channel == channel, Int(m.data1) == number else { return false }
        switch kind {
        case .note: return m.kind == 0x90 || m.kind == 0x80
        case .cc: return m.isCC
        }
    }

    public var description: String {
        let what = kind == .note ? "Note \(number) (\(Cue.noteName(number)))" : "CC \(number)"
        return "\(what), ch \(channel), \(style == .momentary ? "momentary" : "single message")"
    }
}

/// Turns raw controller messages into actions, so one press never triggers twice.
public final class ControlInterpreter {
    public var mappings: [ControlAction: MIDITrigger]
    public static let singleDebounce = 0.25
    public static let momentaryDebounce = 0.05

    private var ccHigh: [MIDITrigger: Bool] = [:]
    private var lastFire: [ControlAction: Double] = [:]

    public init(mappings: [ControlAction: MIDITrigger] = [:]) {
        self.mappings = mappings
    }

    /// - Parameter time: seconds on any monotonic clock.
    public func handle(_ m: MIDIMessage, at time: Double) -> [ControlAction] {
        var out: [ControlAction] = []
        for action in ControlAction.allCases {
            guard let t = mappings[action], t.matches(m), isPress(m, t) else { continue }
            let debounce = t.style == .single ? Self.singleDebounce : Self.momentaryDebounce
            if let last = lastFire[action], time - last < debounce { continue }
            lastFire[action] = time
            out.append(action)
        }
        // Remember CC level per control after evaluating every mapping.
        if m.isCC {
            for t in Set(mappings.values) where t.kind == .cc && t.matches(m) {
                ccHigh[t] = m.data2 >= 64
            }
        }
        return out
    }

    private func isPress(_ m: MIDIMessage, _ t: MIDITrigger) -> Bool {
        switch (t.kind, t.style) {
        case (.note, _):
            return m.isNoteOn
        case (.cc, .momentary):
            // Rising edge: low (or unknown) → high.
            return m.data2 >= 64 && ccHigh[t] != true
        case (.cc, .single):
            return true
        }
    }
}

/// Watches the first press after "Learn" is clicked and works out what kind of control it is.
public struct LearnSession {
    /// How long to wait for a release after the first message.
    public static let releaseWindow = 0.6

    public private(set) var first: MIDIMessage?
    private var firstTime = 0.0
    private var sawRelease = false

    public init() {}

    /// Feed every incoming message. Returns a trigger as soon as it's certain (release seen).
    public mutating func feed(_ m: MIDIMessage, at time: Double) -> MIDITrigger? {
        if let f = first {
            guard m.channel == f.channel, m.data1 == f.data1, m.kind == f.kind || (f.kind == 0x90 && m.kind == 0x80) else {
                return nil
            }
            let release = f.isCC ? (m.data2 < 64 && f.data2 >= 64) : m.isNoteOff
            if release, time - firstTime <= Self.releaseWindow {
                sawRelease = true
                return trigger(style: .momentary)
            }
            return nil
        }
        // Only note-ons and CCs can be learned.
        guard m.isNoteOn || m.isCC else { return nil }
        first = m
        firstTime = time
        return nil
    }

    /// Call once the release window has passed: no release means a single-message control.
    public func finish(at time: Double) -> MIDITrigger? {
        guard first != nil, !sawRelease, time - firstTime >= Self.releaseWindow else { return nil }
        return trigger(style: .single)
    }

    public var isWaitingForRelease: Bool { first != nil && !sawRelease }

    private func trigger(style: MIDITrigger.Style) -> MIDITrigger? {
        guard let f = first else { return nil }
        return MIDITrigger(kind: f.isCC ? .cc : .note, channel: f.channel, number: Int(f.data1), style: style)
    }
}

/// One message TC Trigger sends to show the armed state, set by hand (for controllers that
/// expect something other than an echo of the button's own note or CC).
public struct FeedbackMessage: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case note, cc, programChange

        public var title: String {
            switch self {
            case .note: return "Note"
            case .cc: return "CC"
            case .programChange: return "Program Change"
            }
        }
    }

    public var kind: Kind
    public var channel: Int // 1–16
    /// Note number, CC number, or program number.
    public var number: Int  // 0–127
    /// Velocity (note) or value (CC). Ignored for Program Change.
    public var value: Int   // 0–127

    public init(kind: Kind, channel: Int, number: Int, value: Int) {
        self.kind = kind
        self.channel = min(16, max(1, channel))
        self.number = min(127, max(0, number))
        self.value = min(127, max(0, value))
    }

    public var message: MIDIMessage {
        let ch = UInt8(channel - 1)
        switch kind {
        case .note: return MIDIMessage(0x90 | ch, UInt8(number), UInt8(value))
        case .cc: return MIDIMessage(0xB0 | ch, UInt8(number), UInt8(value))
        case .programChange: return MIDIMessage(0xC0 | ch, UInt8(number), 0)
        }
    }

    public var description: String {
        switch kind {
        case .note: return "Note \(number) vel \(value), ch \(channel)"
        case .cc: return "CC \(number) = \(value), ch \(channel)"
        case .programChange: return "Program Change \(number), ch \(channel)"
        }
    }
}

/// Hand-set armed/disarmed messages. Either may be nil (send nothing in that state).
public struct CustomFeedback: Codable, Equatable, Sendable {
    public var armed: FeedbackMessage?
    public var disarmed: FeedbackMessage?

    public init(armed: FeedbackMessage?, disarmed: FeedbackMessage?) {
        self.armed = armed
        self.disarmed = disarmed
    }

    /// Morningstar MC6 / MC8 / MC10 (Pro): CC 2 "Engage Toggle" puts switch `index` (0 = A) into
    /// toggle position 2 (armed); CC 3 "Disengage Toggle" puts it back to position 1 (disarmed).
    /// Sent on the controller's own MIDI channel (MC8 Pro manual, MIDI implementation).
    public static func morningstar(switchIndex: Int, channel: Int) -> CustomFeedback {
        CustomFeedback(armed: FeedbackMessage(kind: .cc, channel: channel, number: 2, value: switchIndex),
                       disarmed: FeedbackMessage(kind: .cc, channel: channel, number: 3, value: switchIndex))
    }

    /// Switch letters A–X (index 0–23) as Morningstar labels them.
    public static let morningstarSwitches = (0..<24).map { String(UnicodeScalar(UInt8(65 + $0))) }
}

/// Messages built for output.
public enum MIDIMessages {
    /// What to send for the armed state: the custom message if one is set, otherwise the learned
    /// button's own note/CC at 127 (armed) or 0 (disarmed). Nil = nothing to send.
    public static func feedback(learned: MIDITrigger?, custom: CustomFeedback?, armed: Bool) -> MIDIMessage? {
        if let custom { return (armed ? custom.armed : custom.disarmed)?.message }
        return learned.map { feedback($0, armed: armed) }
    }

    /// LED feedback for the armed state: full on when armed, off when disarmed.
    public static func feedback(_ t: MIDITrigger, armed: Bool) -> MIDIMessage {
        let ch = UInt8(t.channel - 1)
        switch t.kind {
        case .note: return MIDIMessage(0x90 | ch, UInt8(t.number), armed ? 127 : 0)
        case .cc: return MIDIMessage(0xB0 | ch, UInt8(t.number), armed ? 127 : 0)
        }
    }

    /// Panic: a note-off for every cue's note on its channel, then All Notes Off (CC 123) on all 16 channels.
    public static func panic(cues: [Cue]) -> [MIDIMessage] {
        var seen = Set<Int>()
        var out: [MIDIMessage] = []
        for c in cues where seen.insert(c.channel * 128 + c.note).inserted {
            out.append(MIDIMessage(0x80 | UInt8(c.channel - 1), UInt8(c.note), 0))
        }
        for ch in 0..<16 { out.append(MIDIMessage(0xB0 | UInt8(ch), 123, 0)) }
        return out
    }
}

/// Fire Next Cue: the next enabled cue after the last one fired (by timecode), or the first
/// enabled cue if nothing has fired yet. Nil when the last fired cue was the final one.
public func nextCueToFire(after lastFiredID: UUID?, in cues: [Cue]) -> Cue? {
    let enabled = CueStore.sorted(cues).filter(\.enabled)
    guard let id = lastFiredID, let last = cues.first(where: { $0.id == id }) else { return enabled.first }
    let sorted = CueStore.sorted(cues)
    guard let pos = sorted.firstIndex(where: { $0.id == last.id }) else { return enabled.first }
    return sorted[(pos + 1)...].first(where: \.enabled)
}
