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

    public init() {}

    enum CodingKeys: String, CodingKey {
        case campusName, audioDeviceUID, audioDeviceName, audioChannel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        campusName = try c.decodeIfPresent(String.self, forKey: .campusName) ?? d.campusName
        audioDeviceUID = try c.decodeIfPresent(String.self, forKey: .audioDeviceUID)
        audioDeviceName = try c.decodeIfPresent(String.self, forKey: .audioDeviceName)
        audioChannel = max(1, try c.decodeIfPresent(Int.self, forKey: .audioChannel) ?? d.audioChannel)
    }
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
    static func diff(_ a: AppSettings, _ b: AppSettings) -> [(String, LogValue, LogValue)] {
        func dict(_ s: AppSettings) -> [String: LogValue] {
            guard let data = try? JSONEncoder().encode(s),
                  let d = try? JSONDecoder().decode([String: LogValue].self, from: data) else { return [:] }
            return d
        }
        let da = dict(a), db = dict(b)
        return Set(da.keys).union(db.keys).sorted().compactMap { key in
            let x = da[key] ?? .null, y = db[key] ?? .null
            return x == y ? nil : (key, x, y)
        }
    }
}
