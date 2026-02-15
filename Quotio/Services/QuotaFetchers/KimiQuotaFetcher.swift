//
//  KimiQuotaFetcher.swift
//  Quotio
//
//  Kimi (Moonshot AI) Quota Fetcher - CLI Mode
//  Uses Kimi CLI's /usage command to fetch coding usage quota
//

import Foundation

// MARK: - Kimi Quota Fetcher

actor KimiQuotaFetcher {
    /// Default paths to search for kimi binary
    private let defaultPaths = [
        "/usr/local/bin/kimi",
        "/opt/homebrew/bin/kimi",
        "/usr/bin/kimi",
    ]
    
    /// Timeout for CLI execution
    private let timeout: TimeInterval = 15.0
    
    init() {}
    
    func updateProxyConfiguration() {
    }
    
    func fetchAsProviderQuota() async -> [String: ProviderQuotaData] {
        Log.quota("KimiQuotaFetcher: Starting fetch")
        guard let kimiPath = findKimiBinary() else {
            Log.quota("Kimi CLI not found in PATH or default locations")
            return [:]
        }
        Log.quota("KimiQuotaFetcher: Found kimi at \(kimiPath)")
        
        do {
            let quotaData = try await fetchQuotaFromCLI(kimiPath: kimiPath)
            Log.quota("KimiQuotaFetcher: Success - \(quotaData.models.count) models")
            return ["kimi-cli": quotaData]
        } catch {
            Log.quota("Failed to fetch Kimi quota via CLI: \(error)")
            return [:]
        }
    }
    
    private func findKimiBinary() -> String? {
        let homeLocalBin = NSString(string: "~/.local/bin/kimi").expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: homeLocalBin) {
            return homeLocalBin
        }
        
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["kimi"]
        
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            
            if whichProcess.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
            }
        } catch {
            Log.quota("Failed to run 'which kimi': \(error)")
        }
        
        for path in defaultPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        
        return nil
    }
    
    private func fetchQuotaFromCLI(kimiPath: String) async throws -> ProviderQuotaData {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try self.runKimiUsageCommand(kimiPath: kimiPath)
                    let quotaData = try Self.parseUsageOutput(output)
                    continuation.resume(returning: quotaData)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private nonisolated func runKimiUsageCommand(kimiPath: String) throws -> String {
        let expectScript = """
        set timeout \(Int(timeout))
        log_user 1
        spawn \(kimiPath)
        expect {
            "💫" { }
            "indo@" { }
            timeout { exit 1 }
        }
        sleep 1
        send "/usage\\r"
        expect {
            "% left" { }
            timeout { exit 1 }
        }
        sleep 2
        send "/exit\\r"
        expect eof
        """
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/usr/bin/expect", "-c", expectScript]
        
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LC_ALL"] = "en_US.UTF-8"
        process.environment = env
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            Log.quota("Kimi CLI expect script failed with status \(process.terminationStatus): \(errorOutput)")
            throw KimiQuotaError.cliExecutionFailed("Exit code: \(process.terminationStatus)")
        }
        
        return output
    }
    
    // MARK: - Parsing
    
    /// Parses CLI /usage output. Expected: "Weekly limit ... N% left (resets in Xd Yh)"
    static func parseUsageOutput(_ text: String) throws -> ProviderQuotaData {
        let cleanText = Self.stripAnsiCodes(text)
        
        var models: [ModelQuota] = []
        
        for line in cleanText.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            
            guard lower.contains("% left") else { continue }
            
            let quotaName: String
            if lower.contains("weekly") {
                quotaName = "kimi-weekly"
            } else if lower.contains("5h") || lower.contains("hour") {
                quotaName = "kimi-5h"
            } else {
                continue
            }
            
            guard let percentMatch = line.range(of: #"(\d+)%\s+left"#, options: .regularExpression),
                  let percent = Double(String(line[percentMatch]).components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) else {
                continue
            }
            
            var resetTimeString = ""
            if let resetMatch = line.range(of: #"\(resets\s+in\s+([^)]+)\)"#, options: .regularExpression) {
                let raw = String(line[resetMatch])
                    .replacingOccurrences(of: "(resets in ", with: "")
                    .replacingOccurrences(of: ")", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if let resetsAt = parseResetDuration(raw) {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    resetTimeString = formatter.string(from: resetsAt)
                }
            }
            
            models.append(ModelQuota(
                name: quotaName,
                percentage: percent,
                resetTime: resetTimeString,
                used: nil,
                limit: nil,
                remaining: nil
            ))
        }
        
        guard !models.isEmpty else {
            throw KimiQuotaError.parseFailed("No quota data found in CLI output")
        }
        
        return ProviderQuotaData(
            models: models,
            lastUpdated: Date(),
            isForbidden: false,
            planType: nil
        )
    }
    
    /// Strips ANSI escape sequences (regex: ESC[ ... m or OSC ... BEL)
    private static func stripAnsiCodes(_ text: String) -> String {
        let pattern = #"\x1B\[[0-9;]*[A-Za-z]|\x1B\][^\x07]*\x07"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
    
    private static func parseResetDuration(_ text: String) -> Date? {
        var totalSeconds: TimeInterval = 0
        
        if let dayMatch = text.range(of: #"(\d+)\s*d"#, options: .regularExpression) {
            let dayStr = String(text[dayMatch])
            if let days = Int(dayStr.filter { $0.isNumber }) {
                totalSeconds += Double(days) * 24 * 3600
            }
        }
        
        if let hourMatch = text.range(of: #"(\d+)\s*h"#, options: .regularExpression) {
            let hourStr = String(text[hourMatch])
            if let hours = Int(hourStr.filter { $0.isNumber }) {
                totalSeconds += Double(hours) * 3600
            }
        }
        
        if let minMatch = text.range(of: #"(\d+)\s*m"#, options: .regularExpression) {
            let minStr = String(text[minMatch])
            if let minutes = Int(minStr.filter { $0.isNumber }) {
                totalSeconds += Double(minutes) * 60
            }
        }
        
        guard totalSeconds > 0 else { return nil }
        return Date().addingTimeInterval(totalSeconds)
    }
}

// MARK: - Errors

enum KimiQuotaError: LocalizedError {
    case cliNotFound
    case cliExecutionFailed(String)
    case parseFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .cliNotFound: return "Kimi CLI not found"
        case .cliExecutionFailed(let msg): return "CLI execution failed: \(msg)"
        case .parseFailed(let msg): return "Failed to parse: \(msg)"
        }
    }
}
