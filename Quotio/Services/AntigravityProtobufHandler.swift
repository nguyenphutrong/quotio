//
//  AntigravityProtobufHandler.swift
//  Quotio
//
//  Handles protobuf encoding/decoding for Antigravity IDE state database.
//  The IDE stores OAuth token in a protobuf-encoded value at field 6.
//

import Foundation

/// Handles protobuf operations for Antigravity IDE token injection
nonisolated enum AntigravityProtobufHandler {
    
    // MARK: - Errors
    
    enum ProtobufError: LocalizedError {
        case incompleteData
        case unknownWireType(UInt8)
        case fieldNotFound(UInt32)
        case invalidBase64
        
        var errorDescription: String? {
            switch self {
            case .incompleteData:
                return "Incomplete protobuf data"
            case .unknownWireType(let type):
                return "Unknown wire type: \(type)"
            case .fieldNotFound(let field):
                return "Field \(field) not found in protobuf"
            case .invalidBase64:
                return "Invalid base64 encoded data"
            }
        }
    }
    
    // MARK: - Varint Encoding/Decoding
    
    /// Encode a UInt64 as protobuf varint
    static func encodeVarint(_ value: UInt64) -> Data {
        var result = Data()
        var val = value
        while val >= 0x80 {
            result.append(UInt8((val & 0x7F) | 0x80))
            val >>= 7
        }
        result.append(UInt8(val))
        return result
    }
    
    /// Read a varint from data at offset, returns (value, newOffset)
    static func readVarint(_ data: Data, offset: Int) throws -> (UInt64, Int) {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var pos = offset
        
        while true {
            guard pos < data.count else {
                throw ProtobufError.incompleteData
            }
            let byte = data[pos]
            result |= UInt64(byte & 0x7F) << shift
            pos += 1
            if byte & 0x80 == 0 {
                break
            }
            shift += 7
        }
        
        return (result, pos)
    }
    
    // MARK: - Field Operations
    
    /// Skip a protobuf field based on wire type
    static func skipField(_ data: Data, offset: Int, wireType: UInt8) throws -> Int {
        switch wireType {
        case 0: // Varint
            let (_, newOffset) = try readVarint(data, offset: offset)
            return newOffset
        case 1: // 64-bit
            return offset + 8
        case 2: // Length-delimited
            let (length, contentOffset) = try readVarint(data, offset: offset)
            return contentOffset + Int(length)
        case 5: // 32-bit
            return offset + 4
        default:
            throw ProtobufError.unknownWireType(wireType)
        }
    }
    
    /// Remove a field from protobuf data
    static func removeField(_ data: Data, fieldNum: UInt32) throws -> Data {
        var result = Data()
        var offset = 0
        
        while offset < data.count {
            let startOffset = offset
            let (tag, newOffset) = try readVarint(data, offset: offset)
            let wireType = UInt8(tag & 7)
            let currentField = UInt32(tag >> 3)
            
            if currentField == fieldNum {
                // Skip this field
                offset = try skipField(data, offset: newOffset, wireType: wireType)
            } else {
                // Keep this field
                let nextOffset = try skipField(data, offset: newOffset, wireType: wireType)
                result.append(data[startOffset..<nextOffset])
                offset = nextOffset
            }
        }
        
        return result
    }
    
    /// Find a length-delimited field and return its content
    static func findField(_ data: Data, targetField: UInt32) throws -> Data? {
        var offset = 0
        
        while offset < data.count {
            guard let (tag, newOffset) = try? readVarint(data, offset: offset) else {
                break
            }
            
            let wireType = UInt8(tag & 7)
            let fieldNum = UInt32(tag >> 3)
            
            if fieldNum == targetField && wireType == 2 {
                let (length, contentOffset) = try readVarint(data, offset: newOffset)
                return Data(data[contentOffset..<(contentOffset + Int(length))])
            }
            
            offset = try skipField(data, offset: newOffset, wireType: wireType)
        }
        
        return nil
    }
    
    // MARK: - OAuth Field Creation
    
    /// Create OAuthTokenInfo protobuf (Field 6)
    /// Structure:
    /// - Field 1: access_token (string)
    /// - Field 2: token_type (string, "Bearer")
    /// - Field 3: refresh_token (string)
    /// - Field 4: expiry (nested Timestamp with Field 1: seconds as int64)
    static func createOAuthField(accessToken: String, refreshToken: String, expiry: Int64) -> Data {
        // Field 1: access_token (string, wire_type = 2)
        let tag1 = encodeVarint((1 << 3) | 2)
        let accessData = Data(accessToken.utf8)
        var field1 = tag1
        field1.append(encodeVarint(UInt64(accessData.count)))
        field1.append(accessData)
        
        // Field 2: token_type (string, fixed value "Bearer", wire_type = 2)
        let tag2 = encodeVarint((2 << 3) | 2)
        let tokenType = "Bearer"
        let tokenTypeData = Data(tokenType.utf8)
        var field2 = tag2
        field2.append(encodeVarint(UInt64(tokenTypeData.count)))
        field2.append(tokenTypeData)
        
        // Field 3: refresh_token (string, wire_type = 2)
        let tag3 = encodeVarint((3 << 3) | 2)
        let refreshData = Data(refreshToken.utf8)
        var field3 = tag3
        field3.append(encodeVarint(UInt64(refreshData.count)))
        field3.append(refreshData)
        
        // Field 4: expiry (nested Timestamp message, wire_type = 2)
        // Timestamp contains: Field 1: seconds (int64, wire_type = 0)
        let timestampTag = encodeVarint((1 << 3) | 0) // Field 1, varint
        var timestampMsg = timestampTag
        timestampMsg.append(encodeVarint(UInt64(bitPattern: expiry)))
        
        let tag4 = encodeVarint((4 << 3) | 2) // Field 4, length-delimited
        var field4 = tag4
        field4.append(encodeVarint(UInt64(timestampMsg.count)))
        field4.append(timestampMsg)
        
        // Combine all fields into OAuthTokenInfo message
        var oauthInfo = Data()
        oauthInfo.append(field1)
        oauthInfo.append(field2)
        oauthInfo.append(field3)
        oauthInfo.append(field4)
        
        // Wrap as Field 6 (length-delimited)
        let tag6 = encodeVarint((6 << 3) | 2)
        var field6 = tag6
        field6.append(encodeVarint(UInt64(oauthInfo.count)))
        field6.append(oauthInfo)
        
        return field6
    }
    
    // MARK: - Token Injection
    
    /// Inject OAuth token into existing protobuf state data
    /// - Parameters:
    ///   - existingData: Current base64-decoded protobuf data from database
    ///   - accessToken: New access token to inject
    ///   - refreshToken: New refresh token to inject
    ///   - expiry: Token expiry timestamp (Unix seconds)
    /// - Returns: New base64-encoded protobuf data ready to write to database
    static func injectToken(
        existingBase64: String,
        accessToken: String,
        refreshToken: String,
        expiry: Int64
    ) throws -> String {
        guard let existingData = Data(base64Encoded: existingBase64) else {
            throw ProtobufError.invalidBase64
        }
        
        // Remove existing Field 6 (OAuth info)
        let dataWithoutOAuth = try removeField(existingData, fieldNum: 6)
        
        // Create new OAuth field
        let newOAuthField = createOAuthField(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiry: expiry
        )
        
        // Append new OAuth field
        var newData = dataWithoutOAuth
        newData.append(newOAuthField)
        
        return newData.base64EncodedString()
    }
    
    /// Extract OAuth info from protobuf data for display/verification
    /// Uses pattern matching to find the OAuth field since the protobuf is deeply nested
    static func extractOAuthInfo(base64Data: String) throws -> (accessToken: String?, refreshToken: String?, expiry: Int64?) {
        guard let data = Data(base64Encoded: base64Data) else {
            throw ProtobufError.invalidBase64
        }
        
        // Search for field 6 tag (0x32) followed by OAuth structure
        // Field 6 contains: field 1 (access_token), field 2 (token_type "Bearer"), field 3 (refresh_token), field 4 (expiry)
        var offset = 0
        
        while offset < data.count - 10 {
            // Look for field 6 tag (0x32 = (6 << 3) | 2)
            if data[offset] == 0x32 {
                // Try to read length
                if let (length, contentOffset) = try? readVarint(data, offset: offset + 1) {
                    let endOffset = contentOffset + Int(length)
                    
                    // Sanity check
                    if endOffset <= data.count && length > 100 && length < 2000 {
                        let potentialOAuth = Data(data[contentOffset..<endOffset])
                        
                        // Check if this looks like OAuth data (should have field 1 with access_token)
                        if let tokenData = try? findField(potentialOAuth, targetField: 1),
                           let tokenString = String(data: tokenData, encoding: .utf8),
                           tokenString.hasPrefix("ya29.") {
                            // Found it! Extract all fields
                            let accessToken: String? = tokenString
                            var refreshToken: String?
                            var expiry: Int64?
                            
                            if let refreshData = try? findField(potentialOAuth, targetField: 3) {
                                refreshToken = String(data: refreshData, encoding: .utf8)
                            }
                            
                            if let expiryData = try? findField(potentialOAuth, targetField: 4) {
                                // Parse nested Timestamp message - skip the tag byte (0x08)
                                if expiryData.count > 1, expiryData[0] == 0x08 {
                                    if let (seconds, _) = try? readVarint(expiryData, offset: 1) {
                                        expiry = Int64(bitPattern: seconds)
                                    }
                                }
                            }
                            
                            return (accessToken, refreshToken, expiry)
                        }
                    }
                }
            }
            offset += 1
        }
        
        // Fall back to structured parsing (for simpler protobuf structures)
        if let oauthData = try? findField(data, targetField: 6) {
            var accessToken: String?
            var refreshToken: String?
            var expiry: Int64?
            
            if let tokenData = try? findField(oauthData, targetField: 1) {
                accessToken = String(data: tokenData, encoding: .utf8)
            }
            
            if let refreshData = try? findField(oauthData, targetField: 3) {
                refreshToken = String(data: refreshData, encoding: .utf8)
            }
            
            if let expiryData = try? findField(oauthData, targetField: 4) {
                if expiryData.count > 1, expiryData[0] == 0x08 {
                    if let (seconds, _) = try? readVarint(expiryData, offset: 1) {
                        expiry = Int64(bitPattern: seconds)
                    }
                }
            }
            
            return (accessToken, refreshToken, expiry)
        }
        
        return (nil, nil, nil)
    }
}
