import Foundation

/// One song launch: when LTC reaches `timecode`, send `note` on `channel` at `velocity`.
public struct Cue: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var timecode: Timecode
    /// MIDI note number 0–127 (60 = C3 in Ableton's naming).
    public var note: Int
    /// MIDI channel 1–16.
    public var channel: Int
    /// 1–127.
    public var velocity: Int
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, timecode: Timecode, note: Int = 60, channel: Int = 1,
                velocity: Int = 127, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.timecode = timecode
        self.note = note
        self.channel = channel
        self.velocity = velocity
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey { case id, name, timecode, note, channel, velocity, enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        let tcString = try c.decode(String.self, forKey: .timecode)
        guard let tc = Timecode(string: tcString) else {
            throw DecodingError.dataCorruptedError(forKey: .timecode, in: c,
                                                   debugDescription: "Invalid timecode \(tcString)")
        }
        timecode = tc
        note = min(127, max(0, try c.decodeIfPresent(Int.self, forKey: .note) ?? 60))
        channel = min(16, max(1, try c.decodeIfPresent(Int.self, forKey: .channel) ?? 1))
        velocity = min(127, max(1, try c.decodeIfPresent(Int.self, forKey: .velocity) ?? 127))
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// Timecode is stored as "HH:MM:SS:FF" so the JSON is easy to read and edit.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(timecode.description, forKey: .timecode)
        try c.encode(note, forKey: .note)
        try c.encode(channel, forKey: .channel)
        try c.encode(velocity, forKey: .velocity)
        try c.encode(enabled, forKey: .enabled)
    }

    /// e.g. "60 (C3)" using Ableton's octave numbering.
    public static func noteName(_ note: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[note % 12])\(note / 12 - 2)"
    }

    var logFields: LogFields {
        ["cue": .string(name), "cue_tc": .string(timecode.description), "note": .int(note),
         "channel": .int(channel), "velocity": .int(velocity), "enabled": .bool(enabled)]
    }
}

/// The cue list, autosaved as JSON. Every change is logged.
public final class CueStore {
    public let fileURL: URL
    private let log: EventLog?
    public private(set) var cues: [Cue]
    public var onChange: (([Cue]) -> Void)?

    public init(fileURL: URL = SettingsStore.defaultDirectory.appendingPathComponent("cues.json"),
                log: EventLog?) {
        self.fileURL = fileURL
        self.log = log
        if let data = try? Data(contentsOf: fileURL) {
            do {
                cues = try JSONDecoder().decode(CueFile.self, from: data).cues
            } catch {
                cues = []
                log?.error(.cue, "cues.load_failed", "Could not read the cue list",
                           ["path": .string(fileURL.path), "error": .string(error.localizedDescription)])
            }
        } else {
            cues = []
        }
    }

    /// Cues sorted by timecode (the list is always kept in this order).
    public static func sorted(_ cues: [Cue]) -> [Cue] {
        cues.enumerated().sorted { a, b in
            a.element.timecode != b.element.timecode ? a.element.timecode < b.element.timecode : a.offset < b.offset
        }.map(\.element)
    }

    public func replaceAll(_ new: [Cue], source: String = "ui") {
        let old = cues
        let sorted = Self.sorted(new)
        guard sorted != old else { return }
        cues = sorted
        logDiff(old: old, new: sorted, source: source)
        save()
        onChange?(sorted)
    }

    public func update(source: String = "ui", _ change: (inout [Cue]) -> Void) {
        var copy = cues
        change(&copy)
        replaceAll(copy, source: source)
    }

    public func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Self.encode(cues).write(to: fileURL, options: .atomic)
        } catch {
            log?.error(.cue, "cues.save_failed", "Could not save the cue list",
                       ["error": .string(error.localizedDescription)])
        }
    }

    public static func encode(_ cues: [Cue]) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(CueFile(cues: cues))
    }

    private func logDiff(old: [Cue], new: [Cue], source: String) {
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        for c in new where oldByID[c.id] == nil {
            log?.info(.cue, "cue.added", "Cue added: \(c.name) at \(c.timecode)", c.logFields.merging(["source": .string(source)]) { a, _ in a })
        }
        for c in old where newByID[c.id] == nil {
            log?.info(.cue, "cue.deleted", "Cue deleted: \(c.name) at \(c.timecode)", c.logFields.merging(["source": .string(source)]) { a, _ in a })
        }
        for c in new {
            guard let before = oldByID[c.id], before != c else { continue }
            if before.enabled != c.enabled, before.with(enabled: c.enabled) == c {
                log?.info(.cue, c.enabled ? "cue.enabled" : "cue.disabled",
                          "Cue \(c.enabled ? "enabled" : "disabled"): \(c.name)", c.logFields)
                continue
            }
            var changes: [String] = []
            var fields: LogFields = ["cue": .string(c.name), "source": .string(source)]
            func note(_ key: String, _ a: LogValue, _ b: LogValue) {
                guard a != b else { return }
                changes.append("\(key) \(a) → \(b)")
                fields["\(key)_old"] = a
                fields["\(key)_new"] = b
            }
            note("name", .string(before.name), .string(c.name))
            note("timecode", .string(before.timecode.description), .string(c.timecode.description))
            note("note", .int(before.note), .int(c.note))
            note("channel", .int(before.channel), .int(c.channel))
            note("velocity", .int(before.velocity), .int(c.velocity))
            note("enabled", .bool(before.enabled), .bool(c.enabled))
            log?.info(.cue, "cue.edited", "Cue edited: \(c.name): \(changes.joined(separator: ", "))", fields)
        }
    }
}

struct CueFile: Codable {
    var format = "tc-trigger-cues"
    var version = 1
    var cues: [Cue]

    init(cues: [Cue]) { self.cues = cues }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cues = try c.decode([Cue].self, forKey: .cues)
    }
}

extension Cue {
    func with(enabled: Bool) -> Cue {
        var c = self
        c.enabled = enabled
        return c
    }
}
