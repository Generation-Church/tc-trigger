import Foundation

/// Reading, listing and pruning the daily log files.
public enum LogFiles {
    public static let maxAgeDays = 90
    public static let maxTotalBytes: Int64 = 500 * 1024 * 1024

    public struct File: Equatable, Sendable {
        public let url: URL
        /// Local calendar day, "yyyy-MM-dd".
        public let day: String
        public let size: Int64
    }

    /// All log files in the folder, oldest first.
    public static func list(in directory: URL) -> [File] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let prefix = EventLog.filePrefix, ext = "." + EventLog.fileExtension
        return names.compactMap { name -> File? in
            guard name.hasPrefix(prefix), name.hasSuffix(ext) else { return nil }
            let day = String(name.dropFirst(prefix.count).dropLast(ext.count))
            guard day.count == 10, dayFormatter(.current).date(from: day) != nil else { return nil }
            let url = directory.appendingPathComponent(name)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return File(url: url, day: day, size: size)
        }
        .sorted { $0.day < $1.day }
    }

    /// Deletes files older than `maxAgeDays`, then the oldest files until the folder is under
    /// `maxTotalBytes`. Today's file (`keepDay`) is never deleted. Returns what was deleted.
    @discardableResult
    public static func prune(directory: URL, now: Date = Date(), timeZone: TimeZone = .current,
                             maxAgeDays: Int = maxAgeDays, maxTotalBytes: Int64 = maxTotalBytes) -> [File] {
        let fmt = dayFormatter(timeZone)
        let keepDay = fmt.string(from: now)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let cutoffDate = cal.date(byAdding: .day, value: -maxAgeDays, to: cal.startOfDay(for: now))!
        let cutoff = fmt.string(from: cutoffDate)

        var files = list(in: directory)
        var deleted: [File] = []
        for f in files where f.day < cutoff && f.day != keepDay {
            if (try? FileManager.default.removeItem(at: f.url)) != nil { deleted.append(f) }
        }
        files.removeAll { deleted.contains($0) }

        var total = files.reduce(0) { $0 + $1.size }
        for f in files where total > maxTotalBytes && f.day != keepDay {
            if (try? FileManager.default.removeItem(at: f.url)) != nil {
                deleted.append(f)
                total -= f.size
            }
        }
        return deleted
    }

    /// Files whose day falls within [from, to] (inclusive, local days).
    public static func files(in directory: URL, from: Date, to: Date, timeZone: TimeZone = .current) -> [File] {
        let fmt = dayFormatter(timeZone)
        let a = fmt.string(from: from), b = fmt.string(from: to)
        return list(in: directory).filter { $0.day >= a && $0.day <= b }
    }

    /// Reads entries between two dates, oldest first. Unreadable lines are skipped.
    public static func read(directory: URL, from: Date, to: Date, limit: Int = 200_000) -> [LogEntry] {
        var out: [LogEntry] = []
        let decoder = entryDecoder()
        for f in files(in: directory, from: from, to: to) {
            guard let data = try? Data(contentsOf: f.url) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let e = try? decoder.decode(LogEntry.self, from: Data(line)),
                      e.timestamp >= from, e.timestamp <= to else { continue }
                out.append(e)
            }
        }
        if out.count > limit { out.removeFirst(out.count - limit) }
        return out
    }

    public static func entryDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSxxx"
        d.dateDecodingStrategy = .formatted(f)
        return d
    }

    static func dayFormatter(_ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
}

extension LogEntry {
    /// For decoding lines written by EventLog (which have no `id`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        level = try c.decode(LogLevel.self, forKey: .level)
        category = (try? c.decode(LogCategory.self, forKey: .category)) ?? .app
        event = try c.decodeIfPresent(String.self, forKey: .event) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        fields = (try? c.decodeIfPresent(LogFields.self, forKey: .fields)) ?? [:]
        campus = try c.decodeIfPresent(String.self, forKey: .campus) ?? ""
        run = try c.decodeIfPresent(String.self, forKey: .run) ?? ""
    }
}
