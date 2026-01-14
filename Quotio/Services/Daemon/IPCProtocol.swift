//
//  IPCProtocol.swift
//  Quotio
//

import Foundation

let ipcJsonRPCVersion = "2.0"

// MARK: - Core Protocol Types

nonisolated struct IPCRequest<P: Encodable & Sendable>: Encodable, Sendable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: P?
    
    init(id: Int, method: String, params: P? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

nonisolated struct IPCResponse<R: Decodable & Sendable>: Decodable, Sendable {
    let jsonrpc: String
    let id: Int?
    let result: R?
    let error: IPCError?
}

nonisolated struct IPCError: Codable, Error, Sendable {
    let code: Int
    let message: String
}

nonisolated enum IPCErrorCode: Int, Sendable {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
    case proxyNotRunning = 1001
    case authFailed = 1002
    case providerNotFound = 1003
    case agentNotFound = 1004
    case configError = 1005
    case daemonAlreadyRunning = 1006
    case daemonNotRunning = 1007
}

nonisolated enum IPCMethod: String, Sendable {
    // Daemon
    case daemonPing = "daemon.ping"
    case daemonStatus = "daemon.status"
    case daemonShutdown = "daemon.shutdown"
    
    // Quota
    case quotaFetch = "quota.fetch"
    case quotaList = "quota.list"
    
    // Agent
    case agentDetect = "agent.detect"
    case agentConfigure = "agent.configure"
    
    // Proxy
    case proxyStart = "proxy.start"
    case proxyStop = "proxy.stop"
    case proxyStatus = "proxy.status"
    case proxyHealth = "proxy.health"
    
    // Auth
    case authList = "auth.list"
    case authDelete = "auth.delete"
    case authOAuth = "auth.oauth"
    case authPoll = "auth.poll"
    
    // Logs
    case logsFetch = "logs.fetch"
    case logsClear = "logs.clear"
    
    // Config
    case configGet = "config.get"
    case configSet = "config.set"
    case configRouting = "config.routing"
    case configDebug = "config.debug"
    case configProxyUrl = "config.proxyUrl"
}

// MARK: - Parameter Types

nonisolated struct IPCEmptyParams: Codable, Sendable {}

nonisolated struct IPCQuotaFetchParams: Codable, Sendable {
    var provider: String?
    var forceRefresh: Bool?
}

nonisolated struct IPCAgentDetectParams: Codable, Sendable {
    var forceRefresh: Bool?
}

nonisolated struct IPCAgentConfigureParams: Codable, Sendable {
    let agent: String
    let mode: String
}

nonisolated struct IPCProxyStartParams: Codable, Sendable {
    var port: Int?
}

nonisolated struct IPCAuthListParams: Codable, Sendable {
    var provider: String?
}

nonisolated struct IPCConfigGetParams: Codable, Sendable {
    let key: String
}

nonisolated struct IPCConfigSetParams: Codable, Sendable {
    let key: String
    let value: IPCAnyCodable
}

nonisolated struct IPCDaemonShutdownParams: Codable, Sendable {
    var graceful: Bool?
}

nonisolated struct IPCAuthDeleteParams: Codable, Sendable {
    let name: String
}

nonisolated struct IPCAuthOAuthParams: Codable, Sendable {
    let provider: String
    var projectId: String?
    var isWebUI: Bool?
}

nonisolated struct IPCAuthPollParams: Codable, Sendable {
    let state: String
}

nonisolated struct IPCLogsFetchParams: Codable, Sendable {
    var after: Int?
}

nonisolated struct IPCConfigRoutingParams: Codable, Sendable {
    var strategy: String?
}

nonisolated struct IPCConfigDebugParams: Codable, Sendable {
    var enabled: Bool?
}

nonisolated struct IPCConfigProxyUrlParams: Codable, Sendable {
    var url: String?
}

// MARK: - Result Types

nonisolated struct IPCDaemonPingResult: Codable, Sendable {
    let pong: Bool
    let timestamp: Int
}

nonisolated struct IPCDaemonStatusResult: Codable, Sendable {
    let running: Bool
    let pid: Int
    let startedAt: String
    let uptime: Int
    let proxyRunning: Bool
    let proxyPort: Int?
    let version: String
}

nonisolated struct IPCQuotaFetchResult: Codable, Sendable {
    let success: Bool
    let quotas: [IPCProviderQuotaInfo]
    let errors: [IPCQuotaError]?
}

nonisolated struct IPCQuotaError: Codable, Sendable {
    let provider: String
    let error: String
}

nonisolated struct IPCProviderQuotaInfo: Codable, Sendable {
    let provider: String
    let email: String
    let models: [IPCModelQuotaInfo]
    let lastUpdated: String
    let isForbidden: Bool
}

nonisolated struct IPCModelQuotaInfo: Codable, Sendable {
    let name: String
    let percentage: Double
    let resetTime: String
    let used: Int?
    let limit: Int?
}

nonisolated struct IPCQuotaListResult: Codable, Sendable {
    let quotas: [IPCProviderQuotaInfo]
    let lastFetched: String?
}

nonisolated struct IPCAgentDetectResult: Codable, Sendable {
    let agents: [IPCDetectedAgent]
}

nonisolated struct IPCDetectedAgent: Codable, Sendable {
    let id: String
    let name: String
    let installed: Bool
    let configured: Bool
    let binaryPath: String?
    let version: String?
}

nonisolated struct IPCAgentConfigureResult: Codable, Sendable {
    let success: Bool
    let agent: String
    let configPath: String?
    let backupPath: String?
}

nonisolated struct IPCProxyStartResult: Codable, Sendable {
    let success: Bool
    let port: Int
    let pid: Int
}

nonisolated struct IPCProxyStatusResult: Codable, Sendable {
    let running: Bool
    let port: Int?
    let pid: Int?
    let startedAt: String?
    let healthy: Bool
}

nonisolated struct IPCProxyHealthResult: Codable, Sendable {
    let healthy: Bool
}

nonisolated struct IPCProxyStopResult: Codable, Sendable {
    let success: Bool
}

nonisolated struct IPCAuthListResult: Codable, Sendable {
    let accounts: [IPCAuthAccount]
}

nonisolated struct IPCAuthAccount: Codable, Sendable {
    let id: String
    let name: String
    let provider: String
    let email: String?
    let status: String
    let disabled: Bool
}

nonisolated struct IPCConfigGetResult: Codable, Sendable {
    let value: IPCAnyCodable
}

nonisolated struct IPCConfigSetResult: Codable, Sendable {
    let success: Bool
}

nonisolated struct IPCAuthDeleteResult: Codable, Sendable {
    let success: Bool
}

nonisolated struct IPCAuthOAuthResult: Codable, Sendable {
    let url: String
    let state: String
}

nonisolated struct IPCAuthPollResult: Codable, Sendable {
    let status: String
    let email: String?
    let error: String?
}

nonisolated struct IPCLogsFetchResult: Codable, Sendable {
    let lines: [String]?
    let lineCount: Int?
    let latestTimestamp: Int?
}

nonisolated struct IPCLogsClearResult: Codable, Sendable {
    let success: Bool
}

nonisolated struct IPCConfigRoutingResult: Codable, Sendable {
    let strategy: String
}

nonisolated struct IPCConfigDebugResult: Codable, Sendable {
    let debug: Bool
}

nonisolated struct IPCConfigProxyUrlResult: Codable, Sendable {
    let proxyUrl: String?
}

// MARK: - Dynamic Value Type

nonisolated enum IPCAnyCodable: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([IPCAnyCodable])
    case object([String: IPCAnyCodable])
    
    init(_ value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let bool as Bool:
            self = .bool(bool)
        case let int as Int:
            self = .int(int)
        case let double as Double:
            self = .double(double)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { IPCAnyCodable($0) })
        case let dict as [String: Any]:
            self = .object(dict.mapValues { IPCAnyCodable($0) })
        default:
            self = .null
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([IPCAnyCodable].self) {
            self = .array(array)
        } else if let dict = try? container.decode([String: IPCAnyCodable].self) {
            self = .object(dict)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
    
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.anyValue)
        case .object(let v): return v.mapValues(\.anyValue)
        }
    }
}
