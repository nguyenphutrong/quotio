# Quotio/Services/Proxy/FallbackFormatConverter.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1190
- **Language:** Swift
- **Symbols:** 28
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 44 | mod | extension AIProvider | (internal) | - |
| 93 | fn | convertRequest | (internal) | `static func convertRequest(     _ body: inout [...` |
| 131 | fn | isClaudeModel | (internal) | `static func isClaudeModel(_ modelName: String) ...` |
| 144 | fn | detectFormat | (internal) | `static func detectFormat(from body: [String: An...` |
| 187 | fn | convertMessages | (internal) | `static func convertMessages(     _ messages: [[...` |
| 230 | fn | convertAnthropicMessagesToOpenAI | (internal) | `static func convertAnthropicMessagesToOpenAI(_ ...` |
| 266 | fn | convertAnthropicAssistantToOpenAI | (internal) | `static func convertAnthropicAssistantToOpenAI(_...` |
| 336 | fn | convertAnthropicUserToOpenAI | (internal) | `static func convertAnthropicUserToOpenAI(_ mess...` |
| 392 | fn | convertOpenAIMessagesToAnthropic | (internal) | `static func convertOpenAIMessagesToAnthropic(_ ...` |
| 452 | fn | convertOpenAIAssistantToAnthropic | (internal) | `static func convertOpenAIAssistantToAnthropic(_...` |
| 487 | fn | convertRole | (internal) | `static func convertRole(_ role: String, from: A...` |
| 509 | fn | convertContent | (internal) | `static func convertContent(_ content: Any, from...` |
| 535 | fn | convertAnthropicContentToOpenAI | (internal) | `static func convertAnthropicContentToOpenAI(_ c...` |
| 604 | fn | convertOpenAIContentToAnthropic | (internal) | `static func convertOpenAIContentToAnthropic(_ c...` |
| 660 | fn | convertGoogleContentToOpenAI | (internal) | `static func convertGoogleContentToOpenAI(_ cont...` |
| 681 | fn | convertToGoogleContent | (internal) | `static func convertToGoogleContent(_ content: A...` |
| 706 | fn | convertSystemMessage | (internal) | `static func convertSystemMessage(in body: inout...` |
| 770 | fn | convertParameters | (internal) | `static func convertParameters(in body: inout [S...` |
| 840 | fn | extractIntValue | (internal) | `static func extractIntValue(_ value: Any?) -> Int?` |
| 849 | fn | convertStopSequences | (internal) | `static func convertStopSequences(in body: inout...` |
| 878 | fn | validateParameters | (internal) | `static func validateParameters(in body: inout [...` |
| 914 | fn | convertTools | (internal) | `static func convertTools(in body: inout [String...` |
| 959 | fn | convertToolFieldsInMessage | (internal) | `static func convertToolFieldsInMessage(_ messag...` |
| 1018 | fn | cleanupIncompatibleFields | (internal) | `static func cleanupIncompatibleFields(in body: ...` |
| 1049 | fn | cleanThinkingBlocksInBody | (internal) | `static func cleanThinkingBlocksInBody(_ body: i...` |
| 1087 | fn | cleanThinkingBlocks | (internal) | `static func cleanThinkingBlocks(_ messages: [[S...` |
| 1119 | fn | cleanThinkingFromContent | (internal) | `static func cleanThinkingFromContent(_ content:...` |
| 1148 | mod | extension FallbackFormatConverter | (internal) | - |

## Memory Markers

### 🟢 `NOTE` (line 46)

> All providers go through cli-proxy-api which uses OpenAI-compatible format

