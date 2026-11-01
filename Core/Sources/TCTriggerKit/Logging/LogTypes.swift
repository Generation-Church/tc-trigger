import Foundation

public enum LogLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case debug, info, warning, error

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

public enum LogCategory: String, Codable, CaseIterable, Sendable {
    case app, audio, ltc, cue, midi, settings
}

/// A value in a log entry's structured fields.
public enum LogValue: Codable, Equatable, Sendable, CustomStringConvertible,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .int(v) }
    public init(floatLiteral v: Double) { self = .double(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(nilLiteral: ()) { self = .null }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var description: String {
        switch self {
        case .string(let v): return v
        case .int(let v): return String(v)
        case .double(let v): return String(format: "%.3f", v)
        case .bool(let v): return v ? "true" : "false"
        case .null: return "–"
        }
    }

    /// The value as a JSON literal.
    var json: String {
        switch self {
        case .string(let v): return JSONText.quote(v)
        case .int(let v): return String(v)
        case .double(let v): return v.isFinite ? String(format: "%.3f", v) : "null"
        case .bool(let v): return v ? "true" : "false"
        case .null: return "null"
        }
    }
}

public typealias LogFields = [String: LogValue]

/// One line of the log.
public struct LogEntry: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var timestamp: Date
    public var level: LogLevel
    public var category: LogCategory
    /// Stable event code such as "cue.fired" or "ltc.lock".
    public var event: String
    public var message: String
    public var fields: LogFields
    public var campus: String
    public var run: String

    enum CodingKeys: String, CodingKey {
        case timestamp = "ts", level = "lvl", category = "cat", event = "evt"
        case message = "msg", fields = "f", campus, run
    }
}

enum JSONText {
    static func quote(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
