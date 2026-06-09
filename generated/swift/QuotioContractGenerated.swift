// Generated from schema/contract.json. Do not edit manually.

public let quotioContractVersion = 1

public enum QuotioRequestKind: String, Sendable {
    case RuntimeStatus = "runtime.status"
    case RuntimeStart = "runtime.start"
    case RuntimeStop = "runtime.stop"
    case ManagementRequest = "management.request"
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
