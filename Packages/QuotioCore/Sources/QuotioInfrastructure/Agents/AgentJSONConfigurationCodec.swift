import Foundation

public enum AgentJSONConfigurationCodec {
    public static func object(from data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }

    public static func data(
        from object: [String: Any],
        withoutEscapingSlashes: Bool = false
    ) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        if withoutEscapingSlashes {
            options.insert(.withoutEscapingSlashes)
        }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    public static func merging(
        existing: Data?,
        updates: [String: Any],
        withoutEscapingSlashes: Bool = false
    ) throws -> Data {
        var object = try object(from: existing)
        for (key, value) in updates {
            object[key] = value
        }
        return try data(from: object, withoutEscapingSlashes: withoutEscapingSlashes)
    }
}
