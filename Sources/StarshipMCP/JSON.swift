import Foundation

/// A JSON value that keeps the order of an object's keys, so the answers read the same way every time, and that keeps
/// whole numbers whole. Written out on one line, as the stdio transport needs.
public indirect enum JSON: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    public static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.double(x), .double(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    /// An object from pairs, leaving out the ones with no value, so that what isn't there isn't sent as null.
    public static func object(dropping pairs: [(String, JSON?)]) -> JSON {
        .object(pairs.compactMap { key, value in value.map { (key, $0) } })
    }

    // MARK: Reading

    public subscript(key: String) -> JSON? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    public var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// A whole number, also when it was written as 12.0.
    public var int: Int? {
        switch self {
        case .int(let number): return number
        case .double(let number) where number.rounded() == number && abs(number) < 1e15: return Int(number)
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .int(let number): return Double(number)
        case .double(let number): return number
        default: return nil
        }
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var array: [JSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    public struct ParseError: Error {}

    public static func parse(_ text: String) throws -> JSON {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { throw ParseError() }
        return from(value)
    }

    private static func from(_ value: Any) -> JSON {
        switch value {
        case let text as String: return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let type = String(cString: number.objCType)
            if ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(type) { return .int(number.intValue) }
            return .double(number.doubleValue)
        case let items as [Any]: return .array(items.map(from))
        case let pairs as [String: Any]: return .object(pairs.sorted { $0.key < $1.key }.map { ($0.key, from($0.value)) })
        default: return .null
        }
    }

    // MARK: Writing

    /// The value on one line.
    public var text: String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .int(let number): out += String(number)
        case .double(let number):
            if !number.isFinite {
                out += "null"
            } else if number.rounded() == number, abs(number) < 1e15 {
                out += String(Int(number))
            } else {
                out += String(number)
            }
        case .string(let text): JSON.quote(text, into: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { out += "," }
                JSON.quote(pair.0, into: &out)
                out += ":"
                pair.1.write(into: &out)
            }
            out += "}"
        }
    }

    private static func quote(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            // Line and paragraph separators are valid JSON, but some readers split lines on them.
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
                ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(elements) }
    public init(nilLiteral: ()) { self = .null }
}
