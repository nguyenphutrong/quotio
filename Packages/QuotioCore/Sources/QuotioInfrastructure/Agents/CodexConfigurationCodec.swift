import Foundation
import QuotioDomain

public struct CodexAuthPayloads: Sendable {
    public let managed: Data
    public let merged: Data
}

public struct CodexConfigurationSnapshot: Sendable {
    public let model: String?
    public let baseURL: String?
    public let reasoningEffort: CodexReasoningEffort?
    public let isProxyConfigured: Bool
}

public enum CodexConfigurationCodec {
    public static func managedTOML(
        model: String,
        proxyURL: String,
        reasoningEffort: CodexReasoningEffort = .defaultEffort
    ) -> String {
        """
        # CLIProxyAPI Configuration for Codex CLI
        model_provider = "cliproxyapi"
        model = "\(escape(model))"
        model_reasoning_effort = "\(escape(reasoningEffort.rawValue))"

        [model_providers.cliproxyapi]
        name = "cliproxyapi"
        base_url = "\(escape(proxyURL))"
        wire_api = "responses"
        """
    }

    public static func snapshot(from content: String) -> CodexConfigurationSnapshot {
        var scanner = TOMLScanner()
        var section: String?
        var model: String?
        var baseURL: String?
        var effort: CodexReasoningEffort?
        var proxy = false

        for line in content.components(separatedBy: .newlines) {
            guard scanner.isStructuralLine(line) else { continue }
            if let newSection = sectionName(from: line) {
                section = newSection
                continue
            }
            if section == nil {
                if let value = stringValue(from: line, key: "model") { model = value }
                if let value = stringValue(from: line, key: "model_provider"), value == "cliproxyapi" { proxy = true }
                if let value = stringValue(from: line, key: "model_reasoning_effort") {
                    effort = CodexReasoningEffort(rawValue: value)
                }
            } else if section == "model_providers.cliproxyapi",
                      let value = stringValue(from: line, key: "base_url") {
                baseURL = value
                proxy = proxy || value.contains("127.0.0.1") || value.contains("localhost")
            }
        }
        return CodexConfigurationSnapshot(
            model: model,
            baseURL: baseURL,
            reasoningEffort: effort,
            isProxyConfigured: proxy
        )
    }

    public static func mergeTOML(existing: String, managed: String) -> String {
        compose(filteredLines: filteredLines(existing: existing, banner: banner(in: managed)), parts: split(managed))
    }

    public static func removingManagedTOML(from existing: String) -> String {
        let stub = managedTOML(model: "", proxyURL: "")
        return filteredLines(existing: existing, banner: banner(in: stub))
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    public static func authPayloads(existing: Data?, apiKey: String) -> CodexAuthPayloads {
        let managed = (try? mergedAuthJSON(existing: nil, apiKey: apiKey))
            ?? Data(#"{"OPENAI_API_KEY":"\#(apiKey)"}"#.utf8)
        guard let existing, let merged = try? mergedAuthJSON(existing: existing, apiKey: apiKey) else {
            return CodexAuthPayloads(managed: managed, merged: managed)
        }
        return CodexAuthPayloads(managed: managed, merged: merged)
    }

    public static func mergedAuthJSON(existing: Data?, apiKey: String) throws -> Data {
        var object: [String: Any] = [:]
        if let existing {
            guard let decoded = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            object = decoded
        }
        object["OPENAI_API_KEY"] = apiKey
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    public static func removingManagedAuthKey(from existing: Data) throws -> Data? {
        guard let decoded = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        guard let key = decoded["OPENAI_API_KEY"] as? String, key.hasPrefix("quotio-") else { return nil }
        var object = decoded
        object.removeValue(forKey: "OPENAI_API_KEY")
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func escape(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x00...0x1F, 0x7F: result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func sectionName(from line: String) -> String? {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("[") else { return nil }
        let array = value.hasPrefix("[[")
        let closing = array ? "]]" : "]"
        guard let end = value.range(of: closing) else { return nil }
        let offset = array ? 2 : 1
        let start = value.index(value.startIndex, offsetBy: offset)
        let name = value[start..<end.lowerBound].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func managedTopLevelKey(_ line: String) -> Bool {
        guard let equal = line.firstIndex(of: "=") else { return false }
        var key = line[..<equal].trimmingCharacters(in: .whitespaces)
        if key.count >= 2, let first = key.first, key.last == first, first == "\"" || first == "'" {
            key = String(key.dropFirst().dropLast())
        }
        return ["model_provider", "model", "model_reasoning_effort"].contains(key)
    }

    private static func stringValue(from line: String, key: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equal = trimmed.firstIndex(of: "=") else { return nil }
        var foundKey = trimmed[..<equal].trimmingCharacters(in: .whitespaces)
        if foundKey.count >= 2, let first = foundKey.first, foundKey.last == first,
           first == "\"" || first == "'" {
            foundKey = String(foundKey.dropFirst().dropLast())
        }
        guard foundKey == key else { return nil }
        return scalarString(String(trimmed[trimmed.index(after: equal)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func scalarString(_ value: String) -> String? {
        let characters = Array(value)
        guard let first = characters.first else { return nil }
        if characters.count >= 3, characters[1] == first, characters[2] == first,
           first == "\"" || first == "'" { return nil }
        if first == "'" {
            guard let end = value.dropFirst().firstIndex(of: "'") else { return nil }
            let result = String(value[value.index(after: value.startIndex)..<end])
            return result.isEmpty ? nil : result
        }
        if first != "\"" {
            let result = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            return result.isEmpty ? nil : result
        }
        var result = ""
        var index = 1
        while index < characters.count {
            if characters[index] == "\"" { return result.isEmpty ? nil : result }
            if characters[index] == "\\" {
                index += 1
                guard index < characters.count else { return nil }
                switch characters[index] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "b": result.append("\u{8}")
                case "f": result.append("\u{c}")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                default: return nil
                }
            } else {
                result.append(characters[index])
            }
            index += 1
        }
        return nil
    }

    private typealias Parts = (top: [String], section: [String])

    private static func split(_ managed: String) -> Parts {
        let lines = managed.components(separatedBy: .newlines)
        guard let index = lines.firstIndex(where: { sectionName(from: $0) != nil }) else { return (lines, []) }
        return (Array(lines[..<index]), Array(lines[index...]))
    }

    private static func banner(in managed: String) -> String? {
        managed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            .flatMap { $0.hasPrefix("#") ? $0 : nil }
    }

    private static func filteredLines(existing: String, banner: String?) -> [String] {
        var output: [String] = []
        var skipProvider = false
        var sawSection = false
        var scanner = TOMLScanner()
        for line in existing.components(separatedBy: .newlines) {
            let structural = scanner.isStructuralLine(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if structural, let section = sectionName(from: trimmed) {
                let managedSection = "model_providers.cliproxyapi"
                if section == managedSection || section.hasPrefix(managedSection + ".") {
                    skipProvider = true
                    continue
                }
                skipProvider = false
                sawSection = true
            }
            if skipProvider { continue }
            if structural, !sawSection, trimmed == banner { continue }
            if structural, !sawSection, managedTopLevelKey(trimmed) { continue }
            output.append(line)
        }
        while output.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { output.removeLast() }
        return output
    }

    private static func compose(filteredLines: [String], parts: Parts) -> String {
        var scanner = TOMLScanner()
        let sectionIndex = filteredLines.enumerated().first(where: {
            scanner.isStructuralLine($0.element) && sectionName(from: $0.element) != nil
        })?.offset ?? filteredLines.count
        var top = Array(filteredLines[..<sectionIndex])
        let sections = Array(filteredLines[sectionIndex...])
        while top.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { top.removeLast() }
        var headerEnd = 0
        while headerEnd < top.count {
            let line = top[headerEnd].trimmingCharacters(in: .whitespaces)
            guard line.isEmpty || line.hasPrefix("#") else { break }
            headerEnd += 1
        }
        var header = Array(top[..<headerEnd])
        var user = Array(top[headerEnd...])
        while header.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { header.removeLast() }
        while user.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { user.removeFirst() }
        while user.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { user.removeLast() }
        var result = header
        appendSeparated(parts.top, to: &result)
        appendSeparated(user, to: &result)
        appendSeparated(parts.section, to: &result)
        appendSeparated(sections, to: &result)
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func appendSeparated(_ lines: [String], to result: inout [String]) {
        guard !lines.isEmpty else { return }
        if result.last?.isEmpty == false { result.append("") }
        result.append(contentsOf: lines)
    }

    private struct TOMLScanner {
        private var multilineQuote: Character?

        mutating func isStructuralLine(_ line: String) -> Bool {
            let characters = Array(line)
            let startedInside = multilineQuote != nil
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if let quote = multilineQuote {
                    if Self.isTriple(characters, index, quote) { multilineQuote = nil; index += 3 } else { index += 1 }
                } else if character == "#" {
                    break
                } else if character == "\"" || character == "'" {
                    if Self.isTriple(characters, index, character) { multilineQuote = character; index += 3 }
                    else { index = Self.endOfString(characters, index, character) }
                } else {
                    index += 1
                }
            }
            return !startedInside
        }

        private static func isTriple(_ characters: [Character], _ index: Int, _ quote: Character) -> Bool {
            index + 2 < characters.count && characters[index + 1] == quote && characters[index + 2] == quote
        }

        private static func endOfString(_ characters: [Character], _ index: Int, _ quote: Character) -> Int {
            var cursor = index + 1
            while cursor < characters.count {
                if quote == "\"", characters[cursor] == "\\" { cursor += 2; continue }
                if characters[cursor] == quote { return cursor + 1 }
                cursor += 1
            }
            return characters.count
        }
    }
}
