import Foundation

/// Everything TC Trigger remembers between launches (except the cue list, which has its own file).
/// Missing keys fall back to defaults, so older settings files keep loading as fields are added.
public struct AppSettings: Codable, Equatable, Sendable {
    public var campusName = ""
    /// Core Audio device UID, or nil to follow the system default input.
    public var audioDeviceUID: String?
    /// Name of the device when it was chosen (shown while it is unplugged).
    public var audioDeviceName: String?
    /// 1-based input channel carrying LTC.
    public var audioChannel = 1
    /// Global firing offset in milliseconds (−1000…+1000). Positive = fire later.
    public var offsetMs = 0
    /// Fire if a frame up to this many frames after the cue is the first one heard.
    public var catchWindowFrames = 3
    /// Armed state, restored at launch. New installs start disarmed.
    public var armed = false
    /// Keeps the "TC Trigger" MIDI source's identity stable across launches.
    public var midiSourceUniqueID: Int32?
    /// MIDI controller input for Arm/Disarm etc. (CoreMIDI unique ID + name to find it again).
    public var controlInputID: Int32?
    public var controlInputName: String?
    /// Learned controls, keyed by ControlAction raw value.
    public var controlMappings: [String: MIDITrigger] = [:]
    /// Where armed-state LED feedback goes, and which note/CC lights the LED.
    public var feedbackDestinationID: Int32?
    public var feedbackDestinationName: String?
    public var feedbackTrigger: MIDITrigger?
    /// Verbose logging is on until this time (it turns itself off after 24 hours).
    public var verboseUntil: Date?
    /// Also show a Dock icon (handy when the menu bar is too full to show TC Trigger's icon).
    public var showInDock = true

    public static let verboseDuration: TimeInterval = 24 * 3600

    public static let offsetRange = -1000...1000
    public static let catchWindowRange = 0...10

    public init() {}

    public func isVerbose(at now: Date = Date()) -> Bool { verboseUntil.map { $0 > now } ?? false }

    public var mappings: [ControlAction: MIDITrigger] {
        Dictionary(uniqueKeysWithValues: controlMappings.compactMap { k, v in ControlAction(rawValue: k).map { ($0, v) } })
    }

    enum CodingKeys: String, CodingKey {
        case campusName, audioDeviceUID, audioDeviceName, audioChannel
        case offsetMs, catchWindowFrames, armed, midiSourceUniqueID
        case controlInputID, controlInputName, controlMappings
        case feedbackDestinationID, feedbackDestinationName, feedbackTrigger
        case verboseUntil, showInDock
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        campusName = try c.decodeIfPresent(String.self, forKey: .campusName) ?? d.campusName
        audioDeviceUID = try c.decodeIfPresent(String.self, forKey: .audioDeviceUID)
        audioDeviceName = try c.decodeIfPresent(String.self, forKey: .audioDeviceName)
        audioChannel = max(1, try c.decodeIfPresent(Int.self, forKey: .audioChannel) ?? d.audioChannel)
        offsetMs = (try c.decodeIfPresent(Int.self, forKey: .offsetMs) ?? d.offsetMs)
            .clamped(to: Self.offsetRange)
        catchWindowFrames = (try c.decodeIfPresent(Int.self, forKey: .catchWindowFrames) ?? d.catchWindowFrames)
            .clamped(to: Self.catchWindowRange)
        armed = try c.decodeIfPresent(Bool.self, forKey: .armed) ?? d.armed
        midiSourceUniqueID = try c.decodeIfPresent(Int32.self, forKey: .midiSourceUniqueID)
        controlInputID = try c.decodeIfPresent(Int32.self, forKey: .controlInputID)
        controlInputName = try c.decodeIfPresent(String.self, forKey: .controlInputName)
        controlMappings = (try? c.decodeIfPresent([String: MIDITrigger].self, forKey: .controlMappings)) ?? [:]
        feedbackDestinationID = try c.decodeIfPresent(Int32.self, forKey: .feedbackDestinationID)
        feedbackDestinationName = try c.decodeIfPresent(String.self, forKey: .feedbackDestinationName)
        feedbackTrigger = try? c.decodeIfPresent(MIDITrigger.self, forKey: .feedbackTrigger)
        verboseUntil = try? c.decodeIfPresent(Date.self, forKey: .verboseUntil)
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? d.showInDock
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

/// Loads and saves AppSettings as JSON and logs every change as old → new.
public final class SettingsStore {
    public let fileURL: URL
    private let log: EventLog?
    public private(set) var settings: AppSettings
    /// Called after every change, on the caller's thread.
    public var onChange: ((AppSettings) -> Void)?

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TC Trigger", isDirectory: true)
    }

    public init(fileURL: URL = SettingsStore.defaultDirectory.appendingPathComponent("settings.json"),
                log: EventLog?) {
        self.fileURL = fileURL
        self.log = log
        if let data = try? Data(contentsOf: fileURL) {
            do {
                settings = try JSONDecoder().decode(AppSettings.self, from: data)
            } catch {
                settings = AppSettings()
                log?.error(.settings, "settings.load_failed", "Could not read settings; using defaults",
                           ["path": .string(fileURL.path), "error": .string(error.localizedDescription)])
            }
        } else {
            settings = AppSettings()
        }
    }

    /// Change settings. `source` says who made the change (e.g. "ui").
    public func update(source: String = "ui", _ change: (inout AppSettings) -> Void) {
        let old = settings
        var new = settings
        change(&new)
        guard new != old else { return }
        settings = new
        for (key, before, after) in Self.diff(old, new) {
            log?.info(.settings, "settings.changed", "\(key): \(before) → \(after)",
                      ["setting": .string(key), "old": before, "new": after, "source": .string(source)])
        }
        save()
        onChange?(new)
    }

    public func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(settings).write(to: fileURL, options: .atomic)
        } catch {
            log?.error(.settings, "settings.save_failed", "Could not save settings",
                       ["error": .string(error.localizedDescription)])
        }
    }

    /// Field-by-field differences, using the JSON form so new fields are covered automatically.
    /// Nested values (e.g. MIDI mappings) are compared and logged as compact JSON text.
    static func diff(_ a: AppSettings, _ b: AppSettings) -> [(String, LogValue, LogValue)] {
        func dict(_ s: AppSettings) -> [String: LogValue] {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            guard let data = try? enc.encode(s),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return obj.mapValues { v in
                if let n = v as? NSNumber {
                    if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
                    return n.doubleValue == n.doubleValue.rounded() ? .int(n.intValue) : .double(n.doubleValue)
                }
                if let str = v as? String { return .string(str) }
                if v is NSNull { return .null }
                let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])
                return .string(d.flatMap { String(data: $0, encoding: .utf8) } ?? "?")
            }
        }
        let da = dict(a), db = dict(b)
        return Set(da.keys).union(db.keys).sorted().compactMap { key in
            let x = da[key] ?? .null, y = db[key] ?? .null
            return x == y ? nil : (key, x, y)
        }
    }
}
