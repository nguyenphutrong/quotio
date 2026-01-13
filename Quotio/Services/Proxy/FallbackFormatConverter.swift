//
//  FallbackFormatConverter.swift
//  Quotio - API Format Conversion for Cross-Provider Fallback
//
//  Handles conversion between different API formats (OpenAI, Anthropic, Google)
//  to enable seamless fallback across providers.
//

import Foundation

// MARK: - API Format Types

/// API format families used by different providers
nonisolated enum APIFormat: String, Sendable {
    case openai     // OpenAI, Codex, Copilot, Cursor, Trae, Kiro (via cli-proxy-api)
    case anthropic  // Claude
    case google     // Gemini, Vertex, Antigravity

    /// Default parameters for this API format
    var defaultMaxTokensParam: String {
        switch self {
        case .openai: return "max_tokens"
        case .anthropic: return "max_tokens"
        case .google: return "maxOutputTokens"
        }
    }

    /// Role name for assistant responses
    var assistantRole: String {
        switch self {
        case .google: return "model"
        default: return "assistant"
        }
    }

    /// Role name for user messages
    var userRole: String {
        return "user"
    }
}

// MARK: - Provider Format Mapping

extension AIProvider {
    /// The API format used by this provider
    /// Note: All providers go through cli-proxy-api which uses OpenAI-compatible format
    /// except Claude (native Anthropic) and Google providers (native Google format)
    nonisolated var apiFormat: APIFormat {
        switch self {
        case .claude:
            return .anthropic
        case .kiro:
            // Kiro receives Anthropic format (CLIProxyAPI handles format conversion)
            return .anthropic
        case .codex, .copilot, .cursor, .trae, .qwen, .iflow, .glm:
            // These use OpenAI-compatible format through cli-proxy-api
            return .openai
        case .gemini, .vertex, .antigravity:
            return .google
        }
    }

    /// Provider-specific parameters that should be adapted
    nonisolated var specificParams: [String] {
        switch self {
        case .antigravity, .gemini, .vertex:
            return ["maxOutputTokens", "temperature", "topP", "topK", "candidateCount", "stopSequences"]
        case .codex:
            return ["max_completion_tokens", "temperature", "top_p", "reasoning_effort", "stop"]
        case .claude, .kiro:
            // Kiro receives Anthropic format (CLIProxyAPI handles format conversion)
            return ["max_tokens", "temperature", "top_p", "top_k", "stop_sequences"]
        case .copilot, .cursor, .trae, .qwen, .iflow, .glm:
            return ["max_tokens", "temperature", "top_p", "stop", "presence_penalty", "frequency_penalty"]
        }
    }
}

// MARK: - Fallback Format Converter

/// Handles all format conversions for cross-provider fallback
/// All methods are nonisolated to allow calling from any context
nonisolated struct FallbackFormatConverter {

    // MARK: - Main Conversion Entry Point

    /// Convert request body from source format to target format
    /// - Parameters:
    ///   - body: Original request body as JSON dictionary
    ///   - sourceProvider: The provider that originally received the request (may be nil if unknown)
    ///   - targetProvider: The provider we're falling back to
    /// - Returns: Converted request body
    static func convertRequest(
        _ body: inout [String: Any],
        from sourceProvider: AIProvider?,
        to targetProvider: AIProvider
    ) {
        let sourceFormat = sourceProvider?.apiFormat ?? detectFormat(from: body)
        let targetFormat = targetProvider.apiFormat

        // Convert messages format
        if let messages = body["messages"] as? [[String: Any]] {
            let convertedMessages = convertMessages(messages, from: sourceFormat, to: targetFormat)
            body["messages"] = convertedMessages
        }

        // Handle system message
        convertSystemMessage(in: &body, from: sourceFormat, to: targetFormat)

        // Convert parameters
        convertParameters(in: &body, to: targetProvider)

        // Convert tool definitions if present
        let toolCount = (body["tools"] as? [[String: Any]])?.count
            ?? (body["functions"] as? [[String: Any]])?.count
            ?? (body["functionDeclarations"] as? [[String: Any]])?.count
            ?? 0
        if toolCount > 0 {
            convertTools(in: &body, from: sourceFormat, to: targetFormat)
        }

        // Clean up format-specific fields
        cleanupIncompatibleFields(in: &body, for: targetFormat)
    }

    // MARK: - Model Detection

    /// Check if a model name is a Claude model
    /// Claude models don't need format conversion from Anthropic format
    /// Checks for: claude, opus, haiku, sonnet keywords
    static func isClaudeModel(_ modelName: String) -> Bool {
        let claudeKeywords = ["claude", "opus", "haiku", "sonnet"]
        let lowerModel = modelName.lowercased()

        return claudeKeywords.contains { keyword in
            lowerModel.contains(keyword)
        }
    }

    // MARK: - Format Detection

    /// Detect the API format from request body structure
    /// More accurate detection with stricter checks
    static func detectFormat(from body: [String: Any]) -> APIFormat {
        // Check for Google-specific fields (most distinctive)
        if body["contents"] != nil || body["generationConfig"] != nil {
            return .google
        }

        // Check for Anthropic-specific fields
        // Anthropic has "system" as a top-level string field (not in messages)
        if let system = body["system"] as? String, !system.isEmpty {
            // Additional check: Anthropic typically has messages as array of blocks
            if let messages = body["messages"] as? [[String: Any]],
               let firstMessage = messages.first,
               let content = firstMessage["content"] as? [[String: Any]] {
                // Claude uses array of blocks
                return .anthropic
            }
            // If system is present as string, it's likely Anthropic
            return .anthropic
        }

        // Check message content format for Anthropic (array of blocks)
        if let messages = body["messages"] as? [[String: Any]],
           let firstMessage = messages.first,
           let content = firstMessage["content"] as? [[String: Any]] {
            // Check if it contains Anthropic-specific block types
            for block in content {
                if let type = block["type"] as? String {
                    if type == "tool_use" || type == "tool_result" || type == "thinking" {
                        return .anthropic
                    }
                }
            }
            // Array of blocks without Anthropic-specific types could still be Anthropic
            return .anthropic
        }

        // Default to OpenAI format (most common)
        return .openai
    }

    // MARK: - Message Conversion

    /// Convert messages array between formats
    static func convertMessages(
        _ messages: [[String: Any]],
        from sourceFormat: APIFormat,
        to targetFormat: APIFormat
    ) -> [[String: Any]] {
        // Special handling: Anthropic → OpenAI requires message-level conversion for tools
        if sourceFormat == .anthropic && targetFormat == .openai {
            return convertAnthropicMessagesToOpenAI(messages)
        }

        // Special handling: OpenAI → Anthropic requires message-level conversion for tools
        if sourceFormat == .openai && targetFormat == .anthropic {
            return convertOpenAIMessagesToAnthropic(messages)
        }

        guard sourceFormat != targetFormat else {
            // No conversion needed if same format - messages are already clean
            return messages
        }

        return messages.map { message in
            var converted = message

            // Convert role names
            if let role = message["role"] as? String {
                converted["role"] = convertRole(role, from: sourceFormat, to: targetFormat)
            }

            // Convert content format
            if let content = message["content"] {
                converted["content"] = convertContent(content, from: sourceFormat, to: targetFormat)
            }

            // Handle tool-related fields in messages
            convertToolFieldsInMessage(&converted, from: sourceFormat, to: targetFormat)

            return converted
        }
    }

    // MARK: - Anthropic to OpenAI Message Conversion

    /// Convert Anthropic messages to OpenAI format (handles tool_use and tool_result)
    static func convertAnthropicMessagesToOpenAI(_ messages: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []

        for message in messages {
            guard let role = message["role"] as? String else {
                result.append(message)
                continue
            }

            // Handle assistant messages with tool_use
            if role == "assistant" {
                let converted = convertAnthropicAssistantToOpenAI(message)
                result.append(converted)
                continue
            }

            // Handle user messages with tool_result
            if role == "user" {
                let convertedMessages = convertAnthropicUserToOpenAI(message)
                result.append(contentsOf: convertedMessages)
                continue
            }

            // Other messages: simple content conversion
            var converted = message
            if let content = message["content"] {
                converted["content"] = convertAnthropicContentToOpenAI(content)
            }
            result.append(converted)
        }

        return result
    }

    /// Convert Anthropic assistant message to OpenAI format
    /// Extracts tool_use blocks and converts to tool_calls
    static func convertAnthropicAssistantToOpenAI(_ message: [String: Any]) -> [String: Any] {
        var converted = message

        guard let content = message["content"] as? [[String: Any]] else {
            // String content - return as-is
            if let strContent = message["content"] as? String {
                converted["content"] = strContent
            }
            return converted
        }

        var textParts: [String] = []
        var toolCalls: [[String: Any]] = []

        for block in content {
            guard let type = block["type"] as? String else { continue }

            switch type {
            case "text":
                if let text = block["text"] as? String {
                    textParts.append(text)
                }
            case "tool_use":
                // Convert to OpenAI tool_calls format
                if let id = block["id"] as? String,
                   let name = block["name"] as? String,
                   let input = block["input"] as? [String: Any] {
                    let argsData = try? JSONSerialization.data(withJSONObject: input)
                    let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

                    toolCalls.append([
                        "id": id,
                        "type": "function",
                        "function": [
                            "name": name,
                            "arguments": argsString
                        ]
                    ])
                }
            case "thinking":
                // Skip thinking blocks for OpenAI
                continue
            default:
                if let text = block["text"] as? String {
                    textParts.append(text)
                }
            }
        }

        // Set content - OpenAI allows null/empty content with tool_calls
        if textParts.isEmpty {
            if !toolCalls.isEmpty {
                converted["content"] = NSNull()
            } else {
                converted["content"] = ""
            }
        } else {
            converted["content"] = textParts.joined(separator: "\n")
        }

        // Add tool_calls if present
        if !toolCalls.isEmpty {
            converted["tool_calls"] = toolCalls
        }

        return converted
    }

    /// Convert Anthropic user message to OpenAI format
    /// Embeds tool_result into user message content (some APIs don't support role: "tool")
    static func convertAnthropicUserToOpenAI(_ message: [String: Any]) -> [[String: Any]] {
        guard let content = message["content"] as? [[String: Any]] else {
            // String content - return as single user message
            return [message]
        }

        var textParts: [String] = []

        for block in content {
            guard let type = block["type"] as? String else { continue }

            switch type {
            case "text":
                if let text = block["text"] as? String {
                    textParts.append(text)
                }
            case "tool_result":
                // Embed tool result into user message content (avoid role: "tool" which some APIs don't support)
                if let toolUseId = block["tool_use_id"] as? String {
                    var resultContent: String

                    if let contentStr = block["content"] as? String {
                        resultContent = contentStr
                    } else if let contentBlocks = block["content"] as? [[String: Any]] {
                        // Extract text from content blocks
                        resultContent = contentBlocks.compactMap { b -> String? in
                            if let text = b["text"] as? String { return text }
                            if let t = b["type"] as? String, t == "text",
                               let text = b["text"] as? String { return text }
                            return nil
                        }.joined(separator: "\n")
                    } else {
                        resultContent = ""
                    }

                    // Embed as formatted text in user message
                    textParts.append("[Tool Result (id: \(toolUseId))]\n\(resultContent)")
                }
            default:
                if let text = block["text"] as? String {
                    textParts.append(text)
                }
            }
        }

        // Return single user message with all content
        if textParts.isEmpty {
            return [["role": "user", "content": ""]]
        }

        return [["role": "user", "content": textParts.joined(separator: "\n\n")]]
    }

    // MARK: - OpenAI to Anthropic Message Conversion

    /// Convert OpenAI messages to Anthropic format (handles tool_calls and tool responses)
    static func convertOpenAIMessagesToAnthropic(_ messages: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var pendingToolResults: [[String: Any]] = []

        for message in messages {
            guard let role = message["role"] as? String else {
                result.append(message)
                continue
            }

            // Collect tool responses to merge into user message
            if role == "tool" {
                if let toolCallId = message["tool_call_id"] as? String,
                   let content = message["content"] as? String {
                    pendingToolResults.append([
                        "type": "tool_result",
                        "tool_use_id": toolCallId,
                        "content": content
                    ])
                }
                continue
            }

            // Before processing next non-tool message, flush pending tool results
            if !pendingToolResults.isEmpty {
                result.append([
                    "role": "user",
                    "content": pendingToolResults
                ])
                pendingToolResults = []
            }

            // Handle assistant messages with tool_calls
            if role == "assistant" {
                let converted = convertOpenAIAssistantToAnthropic(message)
                result.append(converted)
                continue
            }

            // Other messages: convert content to Anthropic format
            var converted = message
            if let content = message["content"] {
                converted["content"] = convertOpenAIContentToAnthropic(content)
            }
            result.append(converted)
        }

        // Flush any remaining tool results
        if !pendingToolResults.isEmpty {
            result.append([
                "role": "user",
                "content": pendingToolResults
            ])
        }

        return result
    }

    /// Convert OpenAI assistant message to Anthropic format
    /// Converts tool_calls to tool_use blocks in content
    static func convertOpenAIAssistantToAnthropic(_ message: [String: Any]) -> [String: Any] {
        var converted = message
        var contentBlocks: [[String: Any]] = []

        // Convert existing content to text block
        if let content = message["content"] as? String, !content.isEmpty {
            contentBlocks.append(["type": "text", "text": content])
        } else if let content = message["content"] as? [[String: Any]] {
            contentBlocks.append(contentsOf: content)
        }

        // Convert tool_calls to tool_use blocks
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                if let function = call["function"] as? [String: Any],
                   let name = function["name"] as? String,
                   let argsString = function["arguments"] as? String,
                   let argsData = argsString.data(using: .utf8),
                   let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                    contentBlocks.append([
                        "type": "tool_use",
                        "id": call["id"] ?? UUID().uuidString,
                        "name": name,
                        "input": args
                    ])
                }
            }
            converted.removeValue(forKey: "tool_calls")
        }

        converted["content"] = contentBlocks
        return converted
    }

    /// Convert role name between formats
    static func convertRole(_ role: String, from: APIFormat, to: APIFormat) -> String {
        // Normalize to common format first
        let normalized: String
        switch role.lowercased() {
        case "model":
            normalized = "assistant"
        case "system", "user", "assistant", "tool":
            normalized = role.lowercased()
        default:
            normalized = role
        }

        // Convert to target format
        switch (normalized, to) {
        case ("assistant", .google):
            return "model"
        default:
            return normalized
        }
    }

    /// Convert content between formats
    static func convertContent(_ content: Any, from sourceFormat: APIFormat, to targetFormat: APIFormat) -> Any {
        switch (sourceFormat, targetFormat) {
        case (.anthropic, .openai):
            // Claude array blocks -> OpenAI string/array
            return convertAnthropicContentToOpenAI(content)

        case (.openai, .anthropic):
            // OpenAI string -> Claude array blocks
            return convertOpenAIContentToAnthropic(content)

        case (.google, .openai), (.google, .anthropic):
            // Google parts -> OpenAI/Claude format
            return convertGoogleContentToOpenAI(content)

        case (.openai, .google), (.anthropic, .google):
            // OpenAI/Claude -> Google parts
            return convertToGoogleContent(content)

        default:
            return cleanThinkingFromContent(content, targetFormat: targetFormat)
        }
    }

    // MARK: - Content Format Converters

    /// Convert Anthropic content blocks to OpenAI format
    static func convertAnthropicContentToOpenAI(_ content: Any) -> Any {
        // If already a string, return as-is
        if let stringContent = content as? String {
            return stringContent
        }

        // Convert array of blocks to string (extracting text only)
        guard let blocks = content as? [[String: Any]] else {
            return content
        }

        var textParts: [String] = []
        var hasNonTextContent = false
        var nonTextBlocks: [[String: Any]] = []

        for block in blocks {
            guard let type = block["type"] as? String else { continue }

            switch type {
            case "text":
                if let text = block["text"] as? String {
                    textParts.append(text)
                }
            case "thinking":
                // Skip thinking blocks - they don't transfer across providers
                continue
            case "image":
                // Convert Claude image to OpenAI image_url format
                hasNonTextContent = true
                if let source = block["source"] as? [String: Any],
                   let mediaType = source["media_type"] as? String,
                   let data = source["data"] as? String {
                    nonTextBlocks.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(mediaType);base64,\(data)"]
                    ])
                }
            case "tool_use":
                // Tool use blocks need special handling
                hasNonTextContent = true
                nonTextBlocks.append(block)
            case "tool_result":
                hasNonTextContent = true
                nonTextBlocks.append(block)
            default:
                hasNonTextContent = true
                nonTextBlocks.append(block)
            }
        }

        // If only text content, return as string
        if !hasNonTextContent && !textParts.isEmpty {
            return textParts.joined(separator: "\n")
        }

        // If has non-text content, return as OpenAI content array
        if hasNonTextContent {
            var result: [[String: Any]] = []
            if !textParts.isEmpty {
                result.append(["type": "text", "text": textParts.joined(separator: "\n")])
            }
            result.append(contentsOf: nonTextBlocks)
            return result
        }

        return textParts.joined(separator: "\n")
    }

    /// Convert OpenAI content to Anthropic format
    static func convertOpenAIContentToAnthropic(_ content: Any) -> Any {
        // If string, convert to text block array
        if let stringContent = content as? String {
            return [["type": "text", "text": stringContent]]
        }

        // If already array, convert each element
        guard let blocks = content as? [[String: Any]] else {
            // Unknown format, wrap in text block
            return [["type": "text", "text": String(describing: content)]]
        }

        return blocks.compactMap { block -> [String: Any]? in
            guard let type = block["type"] as? String else {
                return block
            }

            switch type {
            case "text":
                return block
            case "image_url":
                // Convert OpenAI image_url to Claude image format
                if let imageUrl = block["image_url"] as? [String: Any],
                   let url = imageUrl["url"] as? String {
                    // Parse data URL
                    if url.hasPrefix("data:") {
                        let parts = url.dropFirst(5).split(separator: ";", maxSplits: 1)
                        if parts.count == 2,
                           let base64Part = parts[1].split(separator: ",", maxSplits: 1).last {
                            return [
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "media_type": String(parts[0]),
                                    "data": String(base64Part)
                                ]
                            ]
                        }
                    }
                    // URL-based image
                    return [
                        "type": "image",
                        "source": [
                            "type": "url",
                            "url": url
                        ]
                    ]
                }
                return nil
            default:
                return block
            }
        }
    }

    /// Convert Google parts to OpenAI format
    static func convertGoogleContentToOpenAI(_ content: Any) -> Any {
        // Handle Google "parts" format
        if let parts = content as? [[String: Any]] {
            var textParts: [String] = []
            for part in parts {
                if let text = part["text"] as? String {
                    textParts.append(text)
                }
            }
            return textParts.joined(separator: "\n")
        }

        // Already in compatible format
        if let stringContent = content as? String {
            return stringContent
        }

        return content
    }

    /// Convert content to Google parts format
    static func convertToGoogleContent(_ content: Any) -> Any {
        if let stringContent = content as? String {
            return [["text": stringContent]]
        }

        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block -> [String: Any]? in
                if let text = block["text"] as? String {
                    return ["text": text]
                }
                if let type = block["type"] as? String, type == "text",
                   let text = block["text"] as? String {
                    return ["text": text]
                }
                // Skip non-text content for Google
                return nil
            }
        }

        return [["text": String(describing: content)]]
    }

    // MARK: - System Message Handling

    /// Convert system message between formats
    static func convertSystemMessage(in body: inout [String: Any], from sourceFormat: APIFormat, to targetFormat: APIFormat) {
        var systemContent: String?

        // Extract system content from source format
        switch sourceFormat {
        case .anthropic:
            // Claude has separate "system" field
            if let system = body["system"] as? String {
                systemContent = system
            }
        case .openai:
            // OpenAI has system in messages array
            if var messages = body["messages"] as? [[String: Any]] {
                if let firstIndex = messages.firstIndex(where: { ($0["role"] as? String) == "system" }) {
                    let systemMessage = messages[firstIndex]
                    if let content = systemMessage["content"] as? String {
                        systemContent = content
                    } else if let blocks = systemMessage["content"] as? [[String: Any]],
                              let firstText = blocks.first(where: { ($0["type"] as? String) == "text" }),
                              let text = firstText["text"] as? String {
                        systemContent = text
                    }
                    // Remove from messages if converting to Claude
                    if targetFormat == .anthropic {
                        messages.remove(at: firstIndex)
                        body["messages"] = messages
                    }
                }
            }
        case .google:
            // Google uses system_instruction
            if let instruction = body["system_instruction"] as? [String: Any],
               let parts = instruction["parts"] as? [[String: Any]],
               let text = parts.first?["text"] as? String {
                systemContent = text
            }
        }

        // Apply system content to target format
        guard let system = systemContent else { return }

        switch targetFormat {
        case .anthropic:
            body["system"] = system
            body.removeValue(forKey: "system_instruction")
        case .openai:
            // Add system message at the beginning if not already present
            var messages = body["messages"] as? [[String: Any]] ?? []
            let hasSystemMessage = messages.contains { ($0["role"] as? String) == "system" }
            if !hasSystemMessage {
                messages.insert(["role": "system", "content": system], at: 0)
                body["messages"] = messages
            }
            body.removeValue(forKey: "system")
            body.removeValue(forKey: "system_instruction")
        case .google:
            body["system_instruction"] = ["parts": [["text": system]]]
            body.removeValue(forKey: "system")
        }
    }

    // MARK: - Parameter Conversion

    /// Convert parameters to target provider format
    static func convertParameters(in body: inout [String: Any], to targetProvider: AIProvider) {
        let targetFormat = targetProvider.apiFormat

        // Collect all max tokens values
        let allMaxTokensParams = ["maxOutputTokens", "maxTokens", "max_tokens", "max_completion_tokens"]
        var maxTokensValue: Int?

        for param in allMaxTokensParams {
            if let value = extractIntValue(body[param]) {
                maxTokensValue = value
                break
            }
        }

        // Check generationConfig for Google format
        if maxTokensValue == nil, let genConfig = body["generationConfig"] as? [String: Any] {
            for param in allMaxTokensParams {
                if let value = extractIntValue(genConfig[param]) {
                    maxTokensValue = value
                    break
                }
            }
        }

        // Remove all max tokens params
        for param in allMaxTokensParams {
            body.removeValue(forKey: param)
        }

        // Set target max tokens param
        if let value = maxTokensValue {
            body[targetFormat.defaultMaxTokensParam] = value
        }

        // Handle Google's generationConfig
        if targetFormat == .google {
            var genConfig = body["generationConfig"] as? [String: Any] ?? [:]
            if let value = maxTokensValue {
                genConfig["maxOutputTokens"] = value
            }
            if let temp = body["temperature"] {
                genConfig["temperature"] = temp
                body.removeValue(forKey: "temperature")
            }
            if let topP = body["topP"] ?? body["top_p"] {
                genConfig["topP"] = topP
                body.removeValue(forKey: "topP")
                body.removeValue(forKey: "top_p")
            }
            if let topK = body["topK"] ?? body["top_k"] {
                genConfig["topK"] = topK
                body.removeValue(forKey: "topK")
                body.removeValue(forKey: "top_k")
            }
            if !genConfig.isEmpty {
                body["generationConfig"] = genConfig
            }
        } else {
            // Remove generationConfig for non-Google targets
            body.removeValue(forKey: "generationConfig")
        }

        // Handle stop sequences
        convertStopSequences(in: &body, to: targetFormat)

        // Validate and clean parameters
        validateParameters(in: &body)
    }

    /// Extract integer value from various number types
    static func extractIntValue(_ value: Any?) -> Int? {
        guard let value = value else { return nil }
        if let intValue = value as? Int, intValue >= 1 { return intValue }
        if let doubleValue = value as? Double, doubleValue >= 1 { return Int(doubleValue) }
        if let numberValue = value as? NSNumber, numberValue.intValue >= 1 { return numberValue.intValue }
        return nil
    }

    /// Convert stop sequences between formats
    static func convertStopSequences(in body: inout [String: Any], to targetFormat: APIFormat) {
        let stopParams = ["stop", "stop_sequences", "stopSequences"]
        var stopValue: [String]?

        for param in stopParams {
            if let value = body[param] as? [String] {
                stopValue = value
                body.removeValue(forKey: param)
            } else if let value = body[param] as? String {
                stopValue = [value]
                body.removeValue(forKey: param)
            }
        }

        guard let stops = stopValue, !stops.isEmpty else { return }

        switch targetFormat {
        case .openai:
            body["stop"] = stops
        case .anthropic:
            body["stop_sequences"] = stops
        case .google:
            var genConfig = body["generationConfig"] as? [String: Any] ?? [:]
            genConfig["stopSequences"] = stops
            body["generationConfig"] = genConfig
        }
    }

    /// Validate and clean invalid parameters
    static func validateParameters(in body: inout [String: Any]) {
        // Temperature: 0-2
        if let temp = body["temperature"] {
            if let value = temp as? Double, value < 0 || value > 2 {
                body.removeValue(forKey: "temperature")
            } else if let value = temp as? Int, value < 0 || value > 2 {
                body.removeValue(forKey: "temperature")
            }
        }

        // top_p/topP: 0-1
        for param in ["top_p", "topP"] {
            if let value = body[param] {
                if let doubleValue = value as? Double, doubleValue < 0 || doubleValue > 1 {
                    body.removeValue(forKey: param)
                } else if let intValue = value as? Int, intValue < 0 || intValue > 1 {
                    body.removeValue(forKey: param)
                }
            }
        }

        // top_k/topK: >= 1
        for param in ["top_k", "topK"] {
            if let value = body[param] {
                if let intValue = value as? Int, intValue < 1 {
                    body.removeValue(forKey: param)
                } else if let doubleValue = value as? Double, doubleValue < 1 {
                    body.removeValue(forKey: param)
                }
            }
        }
    }

    // MARK: - Tool Conversion

    /// Convert tool definitions between formats
    static func convertTools(in body: inout [String: Any], from sourceFormat: APIFormat, to targetFormat: APIFormat) {
        guard sourceFormat != targetFormat else { return }

        // Extract tools from source format
        var tools: [[String: Any]]?

        if let t = body["tools"] as? [[String: Any]] {
            tools = t
        } else if let f = body["functions"] as? [[String: Any]] {
            // Legacy OpenAI functions format
            tools = f.map { func_ in
                ["type": "function", "function": func_]
            }
        } else if let fd = body["functionDeclarations"] as? [[String: Any]] {
            // Google format
            tools = fd.map { decl in
                ["type": "function", "function": decl]
            }
        }

        guard let sourceTools = tools else { return }

        // Remove all tool-related fields
        body.removeValue(forKey: "tools")
        body.removeValue(forKey: "functions")
        body.removeValue(forKey: "functionDeclarations")
        body.removeValue(forKey: "tool_choice")
        body.removeValue(forKey: "function_call")

        // Convert to target format
        switch targetFormat {
        case .openai, .anthropic:
            body["tools"] = sourceTools
        case .google:
            let declarations = sourceTools.compactMap { tool -> [String: Any]? in
                if let function = tool["function"] as? [String: Any] {
                    return function
                }
                return tool
            }
            body["functionDeclarations"] = declarations
        }
    }

    /// Convert tool-related fields in individual messages
    static func convertToolFieldsInMessage(_ message: inout [String: Any], from sourceFormat: APIFormat, to targetFormat: APIFormat) {
        // Handle tool_calls (OpenAI) vs tool_use (Claude)
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            if targetFormat == .anthropic {
                // Convert to Claude tool_use blocks in content
                var content = message["content"] as? [[String: Any]] ?? []
                for call in toolCalls {
                    if let function = call["function"] as? [String: Any],
                       let name = function["name"] as? String,
                       let argsString = function["arguments"] as? String,
                       let argsData = argsString.data(using: .utf8),
                       let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                        content.append([
                            "type": "tool_use",
                            "id": call["id"] ?? UUID().uuidString,
                            "name": name,
                            "input": args
                        ])
                    }
                }
                message["content"] = content
                message.removeValue(forKey: "tool_calls")
            }
        }

        // Handle tool_use blocks in content (Claude) -> tool_calls (OpenAI)
        if sourceFormat == .anthropic && targetFormat == .openai {
            if var content = message["content"] as? [[String: Any]] {
                var toolCalls: [[String: Any]] = []
                content = content.filter { block in
                    guard let type = block["type"] as? String, type == "tool_use" else {
                        return true
                    }
                    if let name = block["name"] as? String,
                       let input = block["input"] as? [String: Any],
                       let argsData = try? JSONSerialization.data(withJSONObject: input),
                       let argsString = String(data: argsData, encoding: .utf8) {
                        toolCalls.append([
                            "id": block["id"] ?? UUID().uuidString,
                            "type": "function",
                            "function": [
                                "name": name,
                                "arguments": argsString
                            ]
                        ])
                    }
                    return false
                }
                if !toolCalls.isEmpty {
                    message["tool_calls"] = toolCalls
                }
                message["content"] = content.isEmpty ? "" : content
            }
        }
    }

    // MARK: - Cleanup

    /// Remove fields incompatible with target format
    static func cleanupIncompatibleFields(in body: inout [String: Any], for targetFormat: APIFormat) {
        switch targetFormat {
        case .openai:
            body.removeValue(forKey: "system")  // Uses messages
            body.removeValue(forKey: "system_instruction")
            body.removeValue(forKey: "generationConfig")
            body.removeValue(forKey: "contents")

        case .anthropic:
            body.removeValue(forKey: "system_instruction")
            body.removeValue(forKey: "generationConfig")
            body.removeValue(forKey: "contents")
            body.removeValue(forKey: "functions")
            body.removeValue(forKey: "function_call")

        case .google:
            body.removeValue(forKey: "system")  // Uses system_instruction
            body.removeValue(forKey: "max_tokens")
            body.removeValue(forKey: "max_completion_tokens")
            body.removeValue(forKey: "top_p")
            body.removeValue(forKey: "top_k")
            body.removeValue(forKey: "stop")
            body.removeValue(forKey: "stop_sequences")
        }
    }

    // MARK: - Thinking Block Handling

    /// Clean thinking blocks from request body
    /// For Claude models: keep thinking blocks with valid signature
    /// For non-Claude models: remove all thinking blocks
    static func cleanThinkingBlocksInBody(_ body: inout [String: Any], isClaudeModel: Bool = false) {
        guard var messages = body["messages"] as? [[String: Any]] else {
            return
        }

        messages = messages.map { message in
            var cleaned = message

            if let content = message["content"] as? [[String: Any]] {
                let filteredContent: [[String: Any]] = content.compactMap { block in
                    guard let type = block["type"] as? String else {
                        return block
                    }

                    if type == "thinking" {
                        // For Claude models: keep only if has valid signature
                        if isClaudeModel {
                            if let signature = block["signature"] as? String, !signature.isEmpty {
                                return block
                            }
                            return nil
                        }
                        // For non-Claude models: remove all thinking blocks
                        return nil
                    }

                    return block
                }
                cleaned["content"] = filteredContent
            }

            return cleaned
        }

        body["messages"] = messages
    }

    /// Clean thinking blocks based on target format
    static func cleanThinkingBlocks(_ messages: [[String: Any]], targetFormat: APIFormat) -> [[String: Any]] {
        return messages.map { message in
            var cleaned = message

            if let content = message["content"] as? [[String: Any]] {
                let filteredContent: [[String: Any]] = content.compactMap { block in
                    guard let type = block["type"] as? String else {
                        return block
                    }

                    if type == "thinking" {
                        // For Claude: keep only if has valid signature
                        if targetFormat == .anthropic {
                            if let signature = block["signature"] as? String, !signature.isEmpty {
                                return block
                            }
                            return nil
                        }
                        // For other providers: remove all thinking blocks
                        return nil
                    }

                    return block
                }
                cleaned["content"] = filteredContent
            }

            return cleaned
        }
    }

    /// Clean thinking from content (for single content value)
    static func cleanThinkingFromContent(_ content: Any, targetFormat: APIFormat) -> Any {
        guard let blocks = content as? [[String: Any]] else {
            return content
        }

        let filtered: [[String: Any]] = blocks.compactMap { block in
            guard let type = block["type"] as? String else {
                return block
            }

            if type == "thinking" {
                if targetFormat == .anthropic {
                    if let signature = block["signature"] as? String, !signature.isEmpty {
                        return block
                    }
                    return nil
                }
                return nil
            }

            return block
        }

        return filtered
    }
}

// MARK: - Error Detection

extension FallbackFormatConverter {

    /// Check if response indicates an error that should trigger fallback
    nonisolated static func shouldTriggerFallback(responseData: Data) -> Bool {
        guard let responseString = String(data: responseData.prefix(4096), encoding: .utf8) else {
            return false
        }

        // Check HTTP status code
        if let firstLine = responseString.components(separatedBy: "\r\n").first {
            let parts = firstLine.components(separatedBy: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                switch code {
                case 429, 503, 500, 400, 401, 403, 422:
                    return true
                case 200..<300:
                    return false
                default:
                    break
                }
            }
        }

        // Check error patterns in response body
        let lowercased = responseString.lowercased()
        let errorPatterns = [
            "quota exceeded", "rate limit", "limit reached", "no available account",
            "insufficient_quota", "resource_exhausted", "overloaded", "capacity",
            "too many requests", "throttl", "invalid_request", "bad request",
            "unsupported", "malformed", "validation error", "field required",
            "invalid value", "authentication", "unauthorized", "invalid api key",
            "access denied", "model not found", "model unavailable", "does not exist"
        ]

        for pattern in errorPatterns {
            if lowercased.contains(pattern) {
                return true
            }
        }

        return false
    }
}
