// Generated from schema/contract.json. Do not edit manually.

public let quotioContractVersion = 1

public enum QuotioRequestKind: String, Sendable {
    case RuntimeStatus = "runtime.status"
    case RuntimeStart = "runtime.start"
    case RuntimeStop = "runtime.stop"
    case RuntimeRestart = "runtime.restart"
    case ManagementRequest = "management.request"
    case NativeConfirm = "native.confirm"
    case NativeOpenExternal = "native.openExternal"
    case NativeOpenTextFile = "native.openTextFile"
}

public enum QuotioEventKind: String, Sendable {
    case RuntimeStatusChanged = "runtime.statusChanged"
}

public struct RuntimeStatus: Codable, Sendable, Equatable {
    public let state: String
    public let endpoint: String?
}

public struct ManagementResponse: Codable, Sendable, Equatable {
    public let status: Int
    public let body: String?
}

public struct AgentDescriptor: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let configType: String
    public let binaryNames: [String]
    public let macosConfigPaths: [String]
    public let windowsConfigPaths: [String]
    public let macosSupport: String
    public let windowsSupport: String
    public let backupPolicy: String
    public let docsUrl: String?
}

public struct AgentDetectionStatus: Codable, Sendable, Equatable {
    public let agentId: String
    public let platformSupport: String
    public let installed: Bool
    public let configured: Bool
    public let rollbackAvailable: Bool
    public let binaryPath: String?
    public let version: String?
    public let message: String?
}
