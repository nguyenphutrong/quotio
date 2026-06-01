//
//  LogManagementModels.swift
//  Quotio
//

import Foundation

nonisolated struct LogsResponse: Codable, Sendable {
    let lines: [String]
    let lineCount: Int
    let latestTimestamp: Int?

    enum CodingKeys: String, CodingKey {
        case lines
        case lineCount = "line-count"
        case latestTimestamp = "latest-timestamp"
    }

    init(lines: [String] = [], lineCount: Int = 0, latestTimestamp: Int? = nil) {
        self.lines = lines
        self.lineCount = lineCount
        self.latestTimestamp = latestTimestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lines = try container.decodeIfPresent([String].self, forKey: .lines) ?? []
        lineCount = try container.decodeIfPresent(Int.self, forKey: .lineCount) ?? lines.count
        latestTimestamp = try container.decodeIfPresent(Int.self, forKey: .latestTimestamp)
    }
}

nonisolated struct RequestErrorLogsResponse: Decodable, Sendable {
    let files: [RequestErrorLogFile]

    enum CodingKeys: String, CodingKey {
        case files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decodeIfPresent([RequestErrorLogFile].self, forKey: .files) ?? []
    }
}

nonisolated struct RequestErrorLogFile: Identifiable, Codable, Hashable, Sendable {
    let name: String
    let size: Int64
    let modified: Int64

    var id: String { name }
    var modifiedDate: Date { Date(timeIntervalSince1970: TimeInterval(modified)) }
}
