import Foundation

public struct CueImportError: Error, CustomStringConvertible, Equatable {
    public let description: String
}

/// Reading and writing cue-list files, so the same list can be loaded at every campus.
public enum CueTransfer {
    /// Parses a cue file. Accepts TC Trigger's own format (`{"cues": [...]}`) or a bare array.
    /// Errors name the cue that is wrong, e.g. "Cue 3 (Way Maker): invalid timecode "25:00:00:00"".
    public static func parse(_ data: Data) throws -> [Cue] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CueImportError(description: "This file isn't valid JSON.")
        }
        let items: [Any]
        if let dict = json as? [String: Any] {
            guard let list = dict["cues"] as? [Any] else {
                throw CueImportError(description: "This JSON file has no \"cues\" list. Is it a TC Trigger cue file?")
            }
            items = list
        } else if let list = json as? [Any] {
            items = list
        } else {
            throw CueImportError(description: "This JSON file doesn't contain a cue list.")
        }

        var cues: [Cue] = []
        var seen = Set<UUID>()
        for (n, item) in items.enumerated() {
            let label = "Cue \(n + 1)" + ((item as? [String: Any])?["name"] as? String).map { " (\($0))" }.orEmpty
            guard let dict = item as? [String: Any] else {
                throw CueImportError(description: "\(label) isn't an object.")
            }
            guard let tc = dict["timecode"] as? String else {
                throw CueImportError(description: "\(label) has no timecode.")
            }
            guard Timecode(string: tc) != nil else {
                throw CueImportError(description: "\(label): invalid timecode \"\(tc)\" (use HH:MM:SS:FF).")
            }
            for (key, range) in [("note", 0...127), ("channel", 1...16), ("velocity", 1...127)] {
                if let v = dict[key], !(v is NSNull) {
                    guard let i = v as? Int, range.contains(i) else {
                        throw CueImportError(description: "\(label): \(key) must be \(range.lowerBound)–\(range.upperBound), not \(v).")
                    }
                }
            }
            do {
                var cue = try JSONDecoder().decode(Cue.self, from: JSONSerialization.data(withJSONObject: dict))
                if seen.contains(cue.id) { cue.id = UUID() } // duplicated IDs (hand-edited files)
                seen.insert(cue.id)
                cues.append(cue)
            } catch {
                throw CueImportError(description: "\(label) couldn't be read: \(error.localizedDescription)")
            }
        }
        return CueStore.sorted(cues)
    }

    public static func exportData(_ cues: [Cue]) throws -> Data {
        try CueStore.encode(CueStore.sorted(cues))
    }

    /// Suggested export file name, e.g. "TC-Trigger-Cues_QueenCreek_2026-11-01.json".
    public static func suggestedFileName(campus: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let slug = campus.filter { $0.isLetter || $0.isNumber }
        return "TC-Trigger-Cues_\(slug.isEmpty ? "Campus" : slug)_\(f.string(from: date)).json"
    }
}

extension CueStore {
    /// Replace the list with the cues in a file and log it.
    @discardableResult
    public func importFile(_ url: URL) throws -> [Cue] {
        let cues: [Cue]
        do {
            cues = try CueTransfer.parse(Data(contentsOf: url))
        } catch let e as CueImportError {
            logImportFailure(url, e.description)
            throw e
        } catch {
            logImportFailure(url, error.localizedDescription)
            throw CueImportError(description: "Couldn't open the file: \(error.localizedDescription)")
        }
        let previous = self.cues.count
        replaceAll(cues, source: "import")
        logger?.info(.cue, "cues.imported", "Imported \(cues.count) cue\(cues.count == 1 ? "" : "s") from \(url.lastPathComponent) (replaced \(previous))",
                     ["file": .string(url.lastPathComponent), "path": .string(url.path),
                      "count": .int(cues.count), "replaced": .int(previous),
                      "cues": .string(cues.map { "\($0.timecode) \($0.name)" }.joined(separator: "; "))])
        return cues
    }

    public func exportFile(_ url: URL) throws {
        try CueTransfer.exportData(cues).write(to: url, options: .atomic)
        logger?.info(.cue, "cues.exported", "Exported \(cues.count) cues to \(url.lastPathComponent)",
                     ["file": .string(url.lastPathComponent), "path": .string(url.path), "count": .int(cues.count)])
    }

    private func logImportFailure(_ url: URL, _ reason: String) {
        logger?.error(.cue, "cues.import_failed", "Import of \(url.lastPathComponent) failed: \(reason)",
                      ["file": .string(url.lastPathComponent), "reason": .string(reason)])
    }
}

/// Problems worth showing next to a cue.
public enum CueWarnings {
    /// - Parameter rate: the detected frame rate, if any (checks frames exist at that rate).
    public static func check(_ cues: [Cue], rate: FrameRate?) -> [UUID: [String]] {
        var out: [UUID: [String]] = [:]
        let enabled = cues.filter(\.enabled)
        let byTC = Dictionary(grouping: enabled, by: \.timecode)
        let byNote = Dictionary(grouping: enabled, by: { "\($0.channel)-\($0.note)" })
        for cue in cues {
            var w: [String] = []
            if let rate, !cue.timecode.isValid(at: rate) {
                w.append(rate.isDropFrame && cue.timecode.frames < 2
                         ? "\(cue.timecode) is skipped in 29.97 drop-frame; it will fire on the next frame"
                         : "\(cue.timecode) doesn't exist at \(rate.displayName) (frames go 0–\(rate.nominal - 1))")
            }
            if cue.enabled, (byTC[cue.timecode]?.count ?? 0) > 1 {
                w.append("Another enabled cue has the same timecode; both will fire")
            }
            if cue.enabled, let same = byNote["\(cue.channel)-\(cue.note)"], same.count > 1 {
                let others = same.filter { $0.id != cue.id }.map(\.name).joined(separator: ", ")
                w.append("Same note and channel as \(others); they launch the same thing in Ableton")
            }
            if cue.name.trimmingCharacters(in: .whitespaces).isEmpty {
                w.append("No name — logs will be hard to read")
            }
            if !w.isEmpty { out[cue.id] = w }
        }
        return out
    }
}

extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
