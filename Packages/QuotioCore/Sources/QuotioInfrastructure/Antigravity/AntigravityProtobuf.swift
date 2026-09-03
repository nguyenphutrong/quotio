import Foundation

enum AntigravityProtobuf {
    enum Error: Swift.Error { case corrupt, unsupportedWireType }

    static func encodeVarint(_ input: UInt64) -> Data {
        var value = input
        var data = Data()
        while value >= 0x80 {
            data.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
        return data
    }

    static func readVarint(_ data: Data, at offset: Int) throws -> (UInt64, Int) {
        var value: UInt64 = 0
        var position = offset
        for index in 0..<10 {
            guard position >= 0, position < data.count else { throw Error.corrupt }
            let byte = data[position]
            guard index < 9 || byte & 0x7f <= 1 else { throw Error.corrupt }
            value |= UInt64(byte & 0x7f) << UInt64(index * 7)
            position += 1
            if byte & 0x80 == 0 { return (value, position) }
        }
        throw Error.corrupt
    }

    static func skip(_ data: Data, at offset: Int, wireType: UInt8) throws -> Int {
        switch wireType {
        case 0: return try readVarint(data, at: offset).1
        case 1:
            guard offset <= data.count - 8 else { throw Error.corrupt }
            return offset + 8
        case 2:
            let (length, start) = try readVarint(data, at: offset)
            guard length <= UInt64(data.count - start) else { throw Error.corrupt }
            return start + Int(length)
        case 5:
            guard offset <= data.count - 4 else { throw Error.corrupt }
            return offset + 4
        default: throw Error.unsupportedWireType
        }
    }

    static func findField(_ fieldNumber: UInt32, in data: Data) throws -> Data? {
        var offset = 0
        while offset < data.count {
            let (tag, valueStart) = try readVarint(data, at: offset)
            let wireType = UInt8(tag & 7)
            let currentField = UInt32(tag >> 3)
            if currentField == fieldNumber, wireType == 2 {
                let (length, contentStart) = try readVarint(data, at: valueStart)
                guard length <= UInt64(data.count - contentStart) else { throw Error.corrupt }
                return Data(data[contentStart..<(contentStart + Int(length))])
            }
            offset = try skip(data, at: valueStart, wireType: wireType)
        }
        return nil
    }

    static func extractLegacyOAuthCredential(
        from base64: String
    ) throws -> (accessToken: String?, refreshToken: String?, expiry: Int64?) {
        guard let data = Data(base64Encoded: base64) else { throw Error.corrupt }
        guard let oauth = try findField(6, in: data) else { return (nil, nil, nil) }
        let accessToken = try findField(1, in: oauth).flatMap { String(data: $0, encoding: .utf8) }
        let refreshToken = try findField(3, in: oauth).flatMap { String(data: $0, encoding: .utf8) }
        let expiry: Int64?
        if let timestamp = try findField(4, in: oauth), timestamp.first == 0x08 {
            let (seconds, _) = try readVarint(timestamp, at: 1)
            expiry = Int64(bitPattern: seconds)
        } else {
            expiry = nil
        }
        return (accessToken, refreshToken, expiry)
    }

    static func removingFields(_ fields: Set<UInt32>, from data: Data) throws -> Data {
        var result = Data()
        var offset = 0
        while offset < data.count {
            let fieldStart = offset
            let (tag, valueStart) = try readVarint(data, at: offset)
            let end = try skip(data, at: valueStart, wireType: UInt8(tag & 7))
            if !fields.contains(UInt32(tag >> 3)) { result.append(data[fieldStart..<end]) }
            offset = end
        }
        return result
    }

    static func stringField(_ number: UInt32, _ value: String) -> Data {
        field(number, Data(value.utf8))
    }

    static func field(_ number: UInt32, _ value: Data) -> Data {
        var result = encodeVarint(UInt64(number << 3 | 2))
        result.append(encodeVarint(UInt64(value.count)))
        result.append(value)
        return result
    }

    static func oauth(_ access: String, _ refresh: String, _ expiry: Int64) -> Data {
        var result = stringField(1, access)
        result.append(stringField(2, "Bearer"))
        result.append(stringField(3, refresh))
        var timestamp = encodeVarint(8)
        timestamp.append(encodeVarint(UInt64(bitPattern: expiry)))
        result.append(field(4, timestamp))
        return result
    }

    static func createUnified(_ access: String, _ refresh: String, _ expiry: Int64) -> String {
        let encodedOAuth = oauth(access, refresh, expiry).base64EncodedString()
        let nested = stringField(1, "oauthTokenInfoSentinelKey") + field(2, stringField(1, encodedOAuth))
        return field(1, nested).base64EncodedString()
    }

    static func injectLegacy(
        _ existing: String,
        _ access: String,
        _ refresh: String,
        _ expiry: Int64,
        _ email: String
    ) throws -> String {
        guard let decoded = Data(base64Encoded: existing) else { throw Error.corrupt }
        var result = try removingFields([1, 2, 6], from: decoded)
        result.append(stringField(2, email))
        result.append(field(6, oauth(access, refresh, expiry)))
        return result.base64EncodedString()
    }
}
