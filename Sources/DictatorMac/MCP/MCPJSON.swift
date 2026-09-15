import Foundation
import MLXLMCommon

/// A JSON value, as a concrete Swift enum.
///
/// Three things need the same type and none of them can use `[String: Any]`:
///
/// - **Tool schemas from a server** arrive as arbitrary JSON and have to reach
///   `MLXLMCommon.ToolSpec`, which is `[String: any Sendable]`. A
///   `JSONSerialization` result is `Any` holding `NSNumber`/`NSString`/`NSNull`,
///   and casting that to `any Sendable` is a bridging coin-flip. Re-projecting
///   through concrete Swift cases makes the conversion total and obvious.
/// - **Tool-call arguments** travel from the model, through the approval UI,
///   into a subprocess, and then into a persisted transcript — so the type has
///   to be `Sendable`, `Codable` *and* `Hashable` at once. `Any` is none of them.
/// - **Persisted chat transcripts** replay tool calls and results, so whatever
///   we stored has to decode back into the same shape we sent.
///
/// Deliberately not an `AnyCodable`-style box: the point is that every value in
/// the system is one of these seven things, and the compiler can check it.
enum MCPJSON: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    indirect case array([MCPJSON])
    indirect case object([String: MCPJSON])

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            // Int before Double: JSON has one number type, and decoding 3 as
            // 3.0 would send `{"count": 3.0}` to a server expecting an integer.
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MCPJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: MCPJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: - Bridging

    /// Build from a `JSONSerialization` result. Total: anything it can't
    /// recognise becomes `.null` rather than throwing, because a server's odd
    /// corner of a tool schema shouldn't take down the whole tool list.
    static func from(_ value: Any) -> MCPJSON {
        switch value {
        case is NSNull: return .null
        case let number as NSNumber:
            // NSNumber erases Bool into a number, so ask the underlying type.
            // Without this, `{"streaming": true}` round-trips as `1`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if let int = Int(exactly: number) { return .int(int) }
            return .double(number.doubleValue)
        case let value as String: return .string(value)
        case let value as [Any]: return .array(value.map(MCPJSON.from))
        case let value as [String: Any]: return .object(value.mapValues(MCPJSON.from))
        default: return .null
        }
    }

    /// The value as something `JSONSerialization` will accept.
    var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.jsonObject)
        case .object(let value): return value.mapValues(\.jsonObject)
        }
    }

    /// Build from MLXLMCommon's own JSON enum, which is what a parsed tool
    /// call's arguments arrive as. Same seven cases, different module.
    static func from(jsonValue: JSONValue) -> MCPJSON {
        switch jsonValue {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .int(let value): return .int(value)
        case .double(let value): return .double(value)
        case .string(let value): return .string(value)
        case .array(let value): return .array(value.map(MCPJSON.from(jsonValue:)))
        case .object(let value): return .object(value.mapValues(MCPJSON.from(jsonValue:)))
        }
    }

    /// The value as `any Sendable`, which is what both `ToolSpec` and the raw
    /// chat-template message dictionaries are made of.
    var sendableValue: any Sendable {
        switch self {
        case .null: return ""
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.sendableValue)
        case .object(let value): return value.mapValues(\.sendableValue)
        }
    }

    // MARK: - Accessors

    var objectValue: [String: MCPJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [MCPJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> MCPJSON? { objectValue?[key] }

    /// Compact JSON text. Used for the tool-result payload we hand back to the
    /// model and for the arguments shown in the approval UI.
    var compactString: String {
        if case .string(let value) = self { return value }
        guard JSONSerialization.isValidJSONObject(jsonObject),
              let data = try? JSONSerialization.data(
                withJSONObject: jsonObject, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}

extension MCPJSON {
    /// A tool's `inputSchema` as an `MLXLMCommon.ToolSpec`.
    ///
    /// The models are given OpenAI-style function specs — that's what every
    /// chat template in the catalog renders — so an MCP tool has to be
    /// re-wrapped rather than passed through. A schema that isn't an object
    /// (some servers send `null` for a no-argument tool, which the spec
    /// forbids but reality contains) becomes an empty object schema, which is
    /// the spec's own recommendation for "takes no parameters".
    static func toolSpec(name: String, description: String, inputSchema: MCPJSON) -> ToolSpec {
        let parameters: any Sendable
        if case .object = inputSchema {
            parameters = inputSchema.sendableValue
        } else {
            parameters = ["type": "object", "properties": [String: any Sendable]()]
                as [String: any Sendable]
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters,
            ] as [String: any Sendable],
        ]
    }
}
