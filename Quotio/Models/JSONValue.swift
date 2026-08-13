//
//  JSONValue.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Type-safe representation of arbitrary JSON values, used to preserve
//  unknown fields when auth files are decoded, modified, and re-encoded.
//

import Foundation

/// A type-safe representation of any JSON value.
///
/// Auth file structs use this as a catch-all so fields Quotio does not model
/// (e.g. fields added by newer CLIProxyAPI versions) survive a
/// decode → modify → encode cycle instead of being silently dropped.
nonisolated indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    /// Any JSON number Foundation can materialize exactly.
    ///
    /// `Decimal` is used rather than `Int`/`Double` because it is a base-10 type:
    /// it keeps integers larger than `Int64.max` (e.g. `9223372036854775809`) and
    /// decimal fractions (e.g. `0.1`) byte-identical across a decode → encode cycle,
    /// where `Double` would round them to the nearest binary value.
    case number(Decimal)
    /// Finite literals outside `Decimal`'s exponent range (roughly |exponent| > 128)
    /// but still representable as `Double`, e.g. `1e308`.
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    /// Thrown when a JSON number literal falls outside every numeric type Foundation
    /// can materialize (e.g. `1e400`, which overflows both `Decimal` and `Double`).
    ///
    /// RFC 8259 §6 explicitly allows a parser to limit the range it accepts, and
    /// Foundation does: `JSONDecoder` reports "not representable in Swift" and
    /// `JSONSerialization` rejects the whole document. Unknown fields carrying such a
    /// literal are therefore skipped instead of aborting the auth-file decode.
    nonisolated struct UnrepresentableNumberError: Error, Equatable {}

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(Double.self), value.isFinite {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw UnrepresentableNumberError()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// A dynamic coding key used to read/write arbitrary top-level JSON keys.
nonisolated struct JSONCodingKey: CodingKey, Sendable {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

nonisolated extension JSONValue {
    /// Decodes every top-level key not listed in `knownKeys` from `decoder`.
    ///
    /// Call from a custom `init(from:)` after decoding the typed fields to
    /// capture unrecognized fields so they can be re-emitted on encode.
    ///
    /// A field carrying a number literal Foundation cannot represent is skipped
    /// rather than propagated, so one exotic unknown value can never make an auth
    /// file undecodable and break token refresh.
    static func unknownFields(from decoder: Decoder, excluding knownKeys: Set<String>) throws -> [String: JSONValue] {
        let container = try decoder.container(keyedBy: JSONCodingKey.self)
        var fields: [String: JSONValue] = [:]
        for key in container.allKeys where !knownKeys.contains(key.stringValue) {
            do {
                fields[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            } catch is UnrepresentableNumberError {
                continue
            }
        }
        return fields
    }

    /// Re-encodes previously captured unknown fields alongside the typed fields.
    static func encodeUnknownFields(_ fields: [String: JSONValue], to encoder: Encoder) throws {
        guard !fields.isEmpty else { return }
        var container = encoder.container(keyedBy: JSONCodingKey.self)
        for (key, value) in fields {
            try container.encode(value, forKey: JSONCodingKey(stringValue: key))
        }
    }
}
