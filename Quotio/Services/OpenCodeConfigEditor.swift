import Foundation

/// Reasons an opencode.json document is refused. Every case means "do not
/// write": the caller must leave the user's file exactly as it was (#176).
nonisolated enum OpenCodeConfigError: LocalizedError, Equatable {
    /// The file is not decodable as UTF-8 text.
    case notUTF8
    /// A `/* … */` comment is never closed.
    case unterminatedBlockComment
    /// A string literal is never closed.
    case unterminatedString
    /// The document is not well-formed JSONC at the given 1-based line/column.
    case invalidSyntax(line: Int, column: Int)
    /// The top level of the document is not a JSON object.
    case rootNotObject
    /// A key we need to address unambiguously occurs more than once.
    case duplicateKey(String)
    /// `provider` exists but is not a JSON object, so it cannot be merged into.
    case providerNotObject
    /// The spliced document did not reparse into the expected value.
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .notUTF8:
            return "agents.opencode.parseError.notUTF8".localizedStatic()
        case .unterminatedBlockComment:
            return "agents.opencode.parseError.unterminatedComment".localizedStatic()
        case .unterminatedString:
            return "agents.opencode.parseError.unterminatedString".localizedStatic()
        case let .invalidSyntax(line, column):
            return String(
                format: "agents.opencode.parseError.syntax".localizedStatic(),
                String(line),
                String(column)
            )
        case .rootNotObject:
            return "agents.opencode.parseError.notObject".localizedStatic()
        case let .duplicateKey(key):
            return String(format: "agents.opencode.parseError.duplicateKey".localizedStatic(), key)
        case .providerNotObject:
            return "agents.opencode.parseError.providerNotObject".localizedStatic()
        case .verificationFailed:
            return "agents.opencode.parseError.verification".localizedStatic()
        }
    }
}

/// Field-scoped, comment-preserving editor for opencode.json.
///
/// OpenCode reads its config as JSONC (comments and trailing commas allowed).
/// Issue #176 requires that automatic configuration only touch the Quotio-owned
/// entries under `provider`; everything else — `plugin`, `mcp`, other providers,
/// key order, indentation and comments — must survive verbatim. So instead of
/// reparsing and reserializing the whole document, this editor locates the exact
/// character range of the managed member in the original text and splices it.
///
/// Every operation is fail-closed: if the document cannot be parsed, is
/// ambiguous, or the spliced result does not reparse into the value we intended,
/// the operation throws and the caller leaves the file untouched.
nonisolated enum OpenCodeConfigEditor {

    static let schemaURL = "https://opencode.ai/config.json"

    // MARK: - Public API

    /// Inserts or replaces the given provider entries under `provider`,
    /// preserving all other content of `existing` byte for byte.
    ///
    /// `$schema` is added only when creating a brand-new document; an existing
    /// file that does not declare it is left as the user wrote it.
    /// - Parameter existing: current file contents, or nil/empty for a new file.
    /// - Returns: the full new file contents.
    static func merging(existing: Data?, providers: [String: Any]) throws -> Data {
        if providers.isEmpty, let existing, !existing.isEmpty {
            return existing
        }
        guard let existing, !existing.isEmpty else {
            return try freshDocument(providers: providers)
        }
        let (bom, text) = try decoded(existing)
        guard text.contains(where: { !$0.isWhitespace }) else {
            return try freshDocument(providers: providers)
        }

        let scalars = Array(text.unicodeScalars)
        let root = try parseDocument(scalars)

        var expected = try parsedObject(text)
        var expectedProviders = expected["provider"] as? [String: Any] ?? [:]
        for (key, value) in providers {
            expectedProviders[key] = value
        }
        expected["provider"] = expectedProviders

        var edits: [Edit] = []
        let unit = indentUnit(scalars, root: root)

        if let providerMember = try uniqueMember(named: "provider", in: root, scalars: scalars) {
            guard case let .object(providerObject) = providerMember.value else {
                throw OpenCodeConfigError.providerNotObject
            }
            let memberIndent = lineIndent(scalars, before: providerMember.start)
            let entryIndent = memberIndent + unit
            var newEntries: [String] = []
            for key in providers.keys.sorted() {
                let value = providers[key]!
                if let existingEntry = try uniqueMember(named: key, in: providerObject, scalars: scalars) {
                    // Replace only the value: the key token, the comments around
                    // it and every sibling member stay exactly as the user wrote
                    // them.
                    let valueIndent = lineIndent(scalars, before: existingEntry.start)
                    edits.append(Edit(
                        range: existingEntry.value.range,
                        replacement: rendered(value, indent: valueIndent)
                    ))
                } else {
                    newEntries.append(memberText(key: key, value: value, indent: entryIndent))
                }
            }
            if !newEntries.isEmpty {
                edits.append(contentsOf: insertion(
                    of: newEntries.joined(separator: ",\n" + entryIndent),
                    into: providerObject,
                    scalars: scalars,
                    indent: entryIndent,
                    closeIndent: memberIndent
                ))
            }
        } else {
            let rootIndent = root.members.first.map { lineIndent(scalars, before: $0.start) } ?? unit
            let entryIndent = rootIndent + unit
            let entries = providers.keys.sorted().map {
                memberText(key: $0, value: providers[$0]!, indent: entryIndent)
            }
            let body = "{\n" + entryIndent
                + entries.joined(separator: ",\n" + entryIndent)
                + "\n" + rootIndent + "}"
            edits.append(contentsOf: insertion(
                of: "\"provider\": " + body,
                into: root,
                scalars: scalars,
                indent: rootIndent,
                closeIndent: ""
            ))
        }

        return try applyVerified(edits, to: scalars, bom: bom, expecting: expected)
    }

    /// Removes the given provider entries, preserving all other content.
    ///
    /// - Returns: the new file contents, or nil when none of `keys` is present
    ///   so the caller can leave the file completely untouched.
    static func removingProviders(existing: Data, keys: [String]) throws -> Data? {
        guard !existing.isEmpty else { return nil }
        let (bom, text) = try decoded(existing)
        let scalars = Array(text.unicodeScalars)
        let root = try parseDocument(scalars)

        guard let providerMember = try uniqueMember(named: "provider", in: root, scalars: scalars),
              case let .object(providerObject) = providerMember.value else {
            // No `provider` object at all (or it is not an object): nothing that
            // belongs to Quotio can live there, so leave the file alone.
            return nil
        }

        var present: [Member] = []
        for key in keys.sorted() {
            if let member = try uniqueMember(named: key, in: providerObject, scalars: scalars) {
                present.append(member)
            }
        }
        guard !present.isEmpty else { return nil }

        var expected = try parsedObject(text)
        var expectedProviders = expected["provider"] as? [String: Any] ?? [:]
        for key in keys { expectedProviders.removeValue(forKey: key) }
        if expectedProviders.isEmpty {
            expected.removeValue(forKey: "provider")
        } else {
            expected["provider"] = expectedProviders
        }

        let edits: [Edit]
        if present.count == providerObject.members.count {
            // Every remaining provider is ours: drop the whole `provider` member
            // rather than leaving an empty object behind.
            edits = [Edit(range: deletionRange(of: providerMember, scalars: scalars), replacement: "")]
        } else {
            edits = present.map {
                Edit(range: deletionRange(of: $0, scalars: scalars), replacement: "")
            }
        }

        return try applyVerified(edits, to: scalars, bom: bom, expecting: expected)
    }

    /// Parses opencode.json content into a JSON object.
    ///
    /// A strict `JSONSerialization` parse is attempted first; on failure the
    /// content is reparsed after a JSONC pre-pass that removes comments and
    /// trailing commas. The pre-pass never invents validity: it throws on
    /// unterminated comments/strings and replaces each removed comment with a
    /// space so adjacent tokens cannot fuse into a new, valid token.
    static func parseObject(_ data: Data) throws -> [String: Any] {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return object
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenCodeConfigError.notUTF8
        }
        return try parsedObject(text)
    }

    /// Removes `//` and `/* */` comments and trailing commas from JSONC text.
    ///
    /// String literals (including escapes) are left untouched, so values such as
    /// `"https://opencode.ai/config.json"` survive intact. Each removed comment
    /// is replaced by a single space so that removing it can never join two
    /// tokens into one — `1/* x */2` becomes `1 2` (invalid), never `12`.
    /// Throws on unterminated block comments and unterminated strings instead of
    /// silently discarding the rest of the input.
    static func strippingJSONCSyntax(from text: String) throws -> String {
        let s = Array(text.unicodeScalars)
        var withoutComments: [Unicode.Scalar] = []
        withoutComments.reserveCapacity(s.count)
        var i = 0
        var inString = false
        while i < s.count {
            let c = s[i]
            if inString {
                withoutComments.append(c)
                if c == "\\" {
                    guard i + 1 < s.count else { throw OpenCodeConfigError.unterminatedString }
                    withoutComments.append(s[i + 1])
                    i += 2
                    continue
                }
                if c == "\"" { inString = false }
                i += 1
            } else if c == "\"" {
                inString = true
                withoutComments.append(c)
                i += 1
            } else if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                while i < s.count, s[i] != "\n", s[i] != "\r" { i += 1 }
                withoutComments.append(" ")
            } else if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                var j = i + 2
                while j + 1 < s.count, !(s[j] == "*" && s[j + 1] == "/") { j += 1 }
                guard j + 1 < s.count else { throw OpenCodeConfigError.unterminatedBlockComment }
                i = j + 2
                withoutComments.append(" ")
            } else {
                withoutComments.append(c)
                i += 1
            }
        }
        guard !inString else { throw OpenCodeConfigError.unterminatedString }

        // Second string-aware pass: drop commas whose next non-whitespace
        // character closes an object or array (trailing commas).
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(withoutComments.count)
        i = 0
        inString = false
        while i < withoutComments.count {
            let c = withoutComments[i]
            if inString {
                result.append(c)
                if c == "\\", i + 1 < withoutComments.count {
                    result.append(withoutComments[i + 1])
                    i += 2
                    continue
                }
                if c == "\"" { inString = false }
                i += 1
            } else if c == "\"" {
                inString = true
                result.append(c)
                i += 1
            } else if c == "," {
                var j = i + 1
                while j < withoutComments.count, isWhitespace(withoutComments[j]) { j += 1 }
                if j < withoutComments.count, withoutComments[j] == "}" || withoutComments[j] == "]" {
                    i += 1
                } else {
                    result.append(c)
                    i += 1
                }
            } else {
                result.append(c)
                i += 1
            }
        }
        return String(String.UnicodeScalarView(result))
    }

    // MARK: - Document model

    struct Member {
        let key: String
        /// Index of the opening quote of the key token.
        let start: Int
        let value: Node
    }

    struct ObjectSpan {
        let range: Range<Int>
        let openBrace: Int
        let closeBrace: Int
        let members: [Member]
        /// Index of a trailing comma after the last member, when present.
        let trailingComma: Int?
    }

    indirect enum Node {
        case object(ObjectSpan)
        case other(Range<Int>)

        var range: Range<Int> {
            switch self {
            case let .object(span): return span.range
            case let .other(range): return range
            }
        }
    }

    // MARK: - Splicing

    private struct Edit {
        let range: Range<Int>
        let replacement: String
    }

    /// Decodes file contents as UTF-8. `String(data:encoding:)` swallows a
    /// leading byte order mark, so it is returned separately and restored on
    /// write — the file must come back byte-identical outside `provider`.
    private static func decoded(_ data: Data) throws -> (bom: String, text: String) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenCodeConfigError.notUTF8
        }
        let hasBOM = data.count >= 3 && data[data.startIndex] == 0xEF
            && data[data.index(data.startIndex, offsetBy: 1)] == 0xBB
            && data[data.index(data.startIndex, offsetBy: 2)] == 0xBF
        return (hasBOM && !text.hasPrefix("\u{FEFF}") ? "\u{FEFF}" : "", text)
    }

    private static func applyVerified(
        _ edits: [Edit],
        to scalars: [Unicode.Scalar],
        bom: String,
        expecting expected: [String: Any]
    ) throws -> Data {
        // Match the document's line endings. Inserted text is generated by this
        // type and JSON-escapes any newline inside a value, so no user data can
        // be rewritten by this substitution.
        let usesCRLF = scalars.indices.contains { $0 + 1 < scalars.count && scalars[$0] == "\r" && scalars[$0 + 1] == "\n" }

        var output = scalars
        var limit = scalars.count
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            guard edit.range.upperBound <= limit else { throw OpenCodeConfigError.verificationFailed }
            limit = edit.range.lowerBound
            let replacement = usesCRLF
                ? edit.replacement.replacingOccurrences(of: "\n", with: "\r\n")
                : edit.replacement
            output.replaceSubrange(edit.range, with: Array(replacement.unicodeScalars))
        }
        let text = String(String.UnicodeScalarView(output))

        // Fail closed: only hand back content that reparses into exactly the
        // value we intended. Anything else means the splice was wrong and the
        // user's file must not be overwritten.
        let actual = try parsedObject(text)
        guard NSDictionary(dictionary: actual).isEqual(to: expected) else {
            throw OpenCodeConfigError.verificationFailed
        }
        return Data((bom + text).utf8)
    }

    private static func insertion(
        of memberText: String,
        into object: ObjectSpan,
        scalars: [Unicode.Scalar],
        indent: String,
        closeIndent: String
    ) -> [Edit] {
        guard let last = object.members.last else {
            let interior = (object.openBrace + 1)..<object.closeBrace
            let interiorIsBlank = interior.allSatisfy { isWhitespace(scalars[$0]) }
            if interiorIsBlank {
                return [Edit(
                    range: interior,
                    replacement: "\n" + indent + memberText + "\n" + closeIndent
                )]
            }
            return [Edit(
                range: (object.openBrace + 1)..<(object.openBrace + 1),
                replacement: "\n" + indent + memberText
            )]
        }

        let anchor = object.trailingComma.map { $0 + 1 } ?? last.value.range.upperBound
        let needsComma = object.trailingComma == nil

        // Step over a same-line `// …` comment so the new member starts on its
        // own line instead of being swallowed by that comment.
        var cursor = anchor
        while cursor < scalars.count, scalars[cursor] == " " || scalars[cursor] == "\t" { cursor += 1 }
        let hasTrailingLineComment = cursor + 1 < scalars.count
            && scalars[cursor] == "/" && scalars[cursor + 1] == "/"
        if hasTrailingLineComment {
            while cursor < scalars.count, scalars[cursor] != "\n", scalars[cursor] != "\r" { cursor += 1 }
        } else {
            cursor = anchor
        }

        let member = "\n" + indent + memberText
        guard hasTrailingLineComment else {
            return [Edit(range: anchor..<anchor, replacement: (needsComma ? "," : "") + member)]
        }
        // The separating comma goes directly after the last value so it can
        // never land inside the trailing comment; the member goes after it.
        var edits: [Edit] = []
        if needsComma {
            edits.append(Edit(range: anchor..<anchor, replacement: ","))
        }
        edits.append(Edit(range: cursor..<cursor, replacement: member))
        return edits
    }

    /// Character range to delete so that `member` disappears together with one
    /// adjacent comma and, when it occupied a line of its own, that line.
    private static func deletionRange(
        of member: Member,
        scalars: [Unicode.Scalar]
    ) -> Range<Int> {
        var start = member.start
        var end = member.value.range.upperBound

        var forward = end
        while forward < scalars.count, isWhitespace(scalars[forward]) { forward += 1 }
        if forward < scalars.count, scalars[forward] == "," {
            end = forward + 1
        } else {
            var back = start - 1
            while back >= 0, isWhitespace(scalars[back]) { back -= 1 }
            if back >= 0, scalars[back] == "," {
                start = back
            }
        }

        // Swallow the surrounding blank line, but only horizontal whitespace —
        // never a comment, which may belong to the user.
        var lineStart = start
        while lineStart > 0, scalars[lineStart - 1] == " " || scalars[lineStart - 1] == "\t" { lineStart -= 1 }
        var lineEnd = end
        while lineEnd < scalars.count, scalars[lineEnd] == " " || scalars[lineEnd] == "\t" { lineEnd += 1 }
        let startsLine = lineStart == 0 || scalars[lineStart - 1] == "\n" || scalars[lineStart - 1] == "\r"
        if startsLine, lineEnd < scalars.count {
            if scalars[lineEnd] == "\r", lineEnd + 1 < scalars.count, scalars[lineEnd + 1] == "\n" {
                return lineStart..<(lineEnd + 2)
            }
            if scalars[lineEnd] == "\n" || scalars[lineEnd] == "\r" {
                return lineStart..<(lineEnd + 1)
            }
        }
        return start..<end
    }

    // MARK: - Rendering

    private static func freshDocument(providers: [String: Any]) throws -> Data {
        var object: [String: Any] = ["$schema": schemaURL]
        var entries: [String: Any] = [:]
        for (key, value) in providers { entries[key] = value }
        object["provider"] = entries
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func memberText(key: String, value: Any, indent: String) -> String {
        jsonString(key) + ": " + rendered(value, indent: indent)
    }

    /// Serializes `value` and re-indents its continuation lines to `indent`.
    private static func rendered(_ value: Any, indent: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            return "null"
        }
        let text = String(decoding: data, as: UTF8.self)
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { $0.offset == 0 ? String($0.element) : indent + $0.element }
            .joined(separator: "\n")
    }

    private static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - Layout helpers

    /// Leading horizontal whitespace of the line `index` sits on, or "" when the
    /// member does not start its line.
    private static func lineIndent(_ scalars: [Unicode.Scalar], before index: Int) -> String {
        var i = index
        while i > 0, scalars[i - 1] == " " || scalars[i - 1] == "\t" { i -= 1 }
        guard i == 0 || scalars[i - 1] == "\n" || scalars[i - 1] == "\r" else { return "" }
        return String(String.UnicodeScalarView(scalars[i..<index]))
    }

    /// Indentation step used by the document, defaulting to two spaces.
    private static func indentUnit(_ scalars: [Unicode.Scalar], root: ObjectSpan) -> String {
        for member in root.members {
            let indent = lineIndent(scalars, before: member.start)
            if !indent.isEmpty { return indent }
        }
        return "  "
    }

    // MARK: - Parsing

    private static func parsedObject(_ text: String) throws -> [String: Any] {
        let sanitized = try strippingJSONCSyntax(from: text)
        guard let object = try JSONSerialization.jsonObject(with: Data(sanitized.utf8)) as? [String: Any] else {
            throw OpenCodeConfigError.rootNotObject
        }
        return object
    }

    private static func uniqueMember(
        named name: String,
        in object: ObjectSpan,
        scalars: [Unicode.Scalar]
    ) throws -> Member? {
        let matches = object.members.filter { $0.key == name }
        guard matches.count <= 1 else { throw OpenCodeConfigError.duplicateKey(name) }
        return matches.first
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
    }

    /// Parses the whole document and returns the root object span. Throws unless
    /// the document is a single well-formed JSONC object optionally surrounded
    /// by whitespace and comments.
    static func parseDocument(_ scalars: [Unicode.Scalar]) throws -> ObjectSpan {
        var parser = Parser(scalars: scalars)
        // A UTF-8 BOM is preserved in the output but ignored while parsing.
        if parser.index < scalars.count, scalars[parser.index] == "\u{FEFF}" { parser.index += 1 }
        let node = try parser.parseValue()
        try parser.skipTrivia()
        guard parser.index == scalars.count else { throw parser.syntaxError() }
        guard case let .object(span) = node else { throw OpenCodeConfigError.rootNotObject }
        return span
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        func syntaxError() -> OpenCodeConfigError {
            var line = 1
            var column = 1
            var i = 0
            while i < index, i < scalars.count {
                if scalars[i] == "\n" {
                    line += 1
                    column = 1
                } else {
                    column += 1
                }
                i += 1
            }
            return .invalidSyntax(line: line, column: column)
        }

        mutating func skipTrivia() throws {
            while index < scalars.count {
                let c = scalars[index]
                if isWhitespace(c) {
                    index += 1
                    continue
                }
                if c == "/", index + 1 < scalars.count {
                    if scalars[index + 1] == "/" {
                        index += 2
                        while index < scalars.count, scalars[index] != "\n", scalars[index] != "\r" {
                            index += 1
                        }
                        continue
                    }
                    if scalars[index + 1] == "*" {
                        var j = index + 2
                        while j + 1 < scalars.count, !(scalars[j] == "*" && scalars[j + 1] == "/") { j += 1 }
                        guard j + 1 < scalars.count else { throw OpenCodeConfigError.unterminatedBlockComment }
                        index = j + 2
                        continue
                    }
                }
                return
            }
        }

        mutating func expect(_ scalar: Unicode.Scalar) throws {
            guard index < scalars.count, scalars[index] == scalar else { throw syntaxError() }
            index += 1
        }

        mutating func parseValue() throws -> Node {
            try skipTrivia()
            guard index < scalars.count else { throw syntaxError() }
            let start = index
            switch scalars[index] {
            case "{":
                return .object(try parseObjectSpan())
            case "[":
                try parseArray()
                return .other(start..<index)
            case "\"":
                _ = try parseString()
                return .other(start..<index)
            default:
                try parseLiteral()
                return .other(start..<index)
            }
        }

        mutating func parseObjectSpan() throws -> ObjectSpan {
            let start = index
            try expect("{")
            var members: [Member] = []
            var trailingComma: Int?
            while true {
                try skipTrivia()
                guard index < scalars.count else { throw syntaxError() }
                if scalars[index] == "}" {
                    let close = index
                    index += 1
                    return ObjectSpan(
                        range: start..<index,
                        openBrace: start,
                        closeBrace: close,
                        members: members,
                        trailingComma: trailingComma
                    )
                }
                guard scalars[index] == "\"" else { throw syntaxError() }
                let keyStart = index
                let key = try parseString()
                try skipTrivia()
                try expect(":")
                let value = try parseValue()
                members.append(Member(key: key, start: keyStart, value: value))
                trailingComma = nil
                try skipTrivia()
                guard index < scalars.count else { throw syntaxError() }
                if scalars[index] == "," {
                    trailingComma = index
                    index += 1
                    continue
                }
                guard scalars[index] == "}" else { throw syntaxError() }
            }
        }

        mutating func parseArray() throws {
            try expect("[")
            while true {
                try skipTrivia()
                guard index < scalars.count else { throw syntaxError() }
                if scalars[index] == "]" {
                    index += 1
                    return
                }
                _ = try parseValue()
                try skipTrivia()
                guard index < scalars.count else { throw syntaxError() }
                if scalars[index] == "," {
                    index += 1
                    continue
                }
                guard scalars[index] == "]" else { throw syntaxError() }
            }
        }

        @discardableResult
        mutating func parseString() throws -> String {
            try expect("\"")
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let c = scalars[index]
                if c == "\\" {
                    guard index + 1 < scalars.count else { throw OpenCodeConfigError.unterminatedString }
                    out.append(c)
                    out.append(scalars[index + 1])
                    index += 2
                    continue
                }
                if c == "\"" {
                    index += 1
                    return unescaped(String(out))
                }
                if c == "\n" || c == "\r" { throw OpenCodeConfigError.unterminatedString }
                out.append(c)
                index += 1
            }
            throw OpenCodeConfigError.unterminatedString
        }

        /// Decodes the escape sequences of an already-delimited JSON string body.
        /// Only used for member keys, which we compare against ASCII literals.
        private func unescaped(_ raw: String) -> String {
            guard raw.contains("\\") else { return raw }
            let quoted = "\"\(raw)\""
            if let data = quoted.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(
                   with: data,
                   options: [.fragmentsAllowed]
               ) as? String {
                return value
            }
            return raw
        }

        mutating func parseLiteral() throws {
            let start = index
            while index < scalars.count {
                let c = scalars[index]
                if isWhitespace(c) || c == "," || c == "}" || c == "]" || c == "/" { break }
                index += 1
            }
            guard index > start else { throw syntaxError() }
        }
    }
}
