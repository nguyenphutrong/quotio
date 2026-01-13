/**
 * FallbackFormatConverter - API Format Conversion for Cross-Provider Fallback
 *
 * Handles conversion between different API formats (OpenAI, Anthropic, Google)
 * to enable seamless fallback across providers.
 *
 * Ported from Swift: Quotio/Services/Proxy/FallbackFormatConverter.swift
 */

import { randomUUID } from "node:crypto";
import { AIProvider } from "../models/provider.ts";

// MARK: - API Format Types

/**
 * API format families used by different providers
 */
export enum APIFormat {
	OPENAI = "openai", // OpenAI, Codex, Copilot, Cursor, Trae, Kiro (via cli-proxy-api)
	ANTHROPIC = "anthropic", // Claude
	GOOGLE = "google", // Gemini, Vertex, Antigravity
}

/**
 * Get default max tokens parameter name for format
 */
export function getDefaultMaxTokensParam(format: APIFormat): string {
	switch (format) {
		case APIFormat.OPENAI:
			return "max_tokens";
		case APIFormat.ANTHROPIC:
			return "max_tokens";
		case APIFormat.GOOGLE:
			return "maxOutputTokens";
	}
}

/**
 * Get assistant role name for format
 */
export function getAssistantRole(format: APIFormat): string {
	switch (format) {
		case APIFormat.GOOGLE:
			return "model";
		default:
			return "assistant";
	}
}

// MARK: - Provider Format Mapping

/**
 * Get the API format used by a provider
 */
export function getApiFormat(provider: AIProvider): APIFormat {
	switch (provider) {
		case AIProvider.CLAUDE:
			return APIFormat.ANTHROPIC;
		case AIProvider.KIRO:
			// Kiro receives Anthropic format (CLIProxyAPI handles format conversion)
			return APIFormat.ANTHROPIC;
		case AIProvider.CODEX:
		case AIProvider.COPILOT:
		case AIProvider.CURSOR:
		case AIProvider.TRAE:
		case AIProvider.QWEN:
		case AIProvider.IFLOW:
		case AIProvider.GLM:
			// These use OpenAI-compatible format through cli-proxy-api
			return APIFormat.OPENAI;
		case AIProvider.GEMINI:
		case AIProvider.VERTEX:
		case AIProvider.ANTIGRAVITY:
			return APIFormat.GOOGLE;
		default:
			return APIFormat.OPENAI;
	}
}

/**
 * Get provider-specific parameters that should be adapted
 */
export function getSpecificParams(provider: AIProvider): string[] {
	switch (provider) {
		case AIProvider.ANTIGRAVITY:
		case AIProvider.GEMINI:
		case AIProvider.VERTEX:
			return [
				"maxOutputTokens",
				"temperature",
				"topP",
				"topK",
				"candidateCount",
				"stopSequences",
			];
		case AIProvider.CODEX:
			return [
				"max_completion_tokens",
				"temperature",
				"top_p",
				"reasoning_effort",
				"stop",
			];
		case AIProvider.CLAUDE:
		case AIProvider.KIRO:
			return ["max_tokens", "temperature", "top_p", "top_k", "stop_sequences"];
		case AIProvider.COPILOT:
		case AIProvider.CURSOR:
		case AIProvider.TRAE:
		case AIProvider.QWEN:
		case AIProvider.IFLOW:
		case AIProvider.GLM:
			return [
				"max_tokens",
				"temperature",
				"top_p",
				"stop",
				"presence_penalty",
				"frequency_penalty",
			];
		default:
			return [];
	}
}

// MARK: - Type Definitions

type JSONValue =
	| string
	| number
	| boolean
	| null
	| JSONValue[]
	| { [key: string]: JSONValue | undefined };
type JSONObject = { [key: string]: JSONValue | undefined };
type MessageContent = string | JSONObject[];

interface Message {
	role?: string;
	content?: MessageContent;
	tool_calls?: JSONObject[];
	tool_call_id?: string;
	[key: string]: JSONValue | undefined;
}

// MARK: - Main Conversion Entry Point

/**
 * Convert request body from source format to target format
 */
export function convertRequest(
	body: JSONObject,
	sourceProvider: AIProvider | null,
	targetProvider: AIProvider,
): JSONObject {
	const result = { ...body };
	const sourceFormat = sourceProvider
		? getApiFormat(sourceProvider)
		: detectFormat(body);
	const targetFormat = getApiFormat(targetProvider);

	// Convert messages format
	if (Array.isArray(result.messages)) {
		result.messages = convertMessages(
			result.messages as JSONObject[],
			sourceFormat,
			targetFormat,
		);
	}

	// Handle system message
	convertSystemMessage(result, sourceFormat, targetFormat);

	// Convert parameters
	convertParameters(result, targetProvider);

	// Convert tool definitions if present
	const toolCount =
		(result.tools as JSONObject[])?.length ||
		(result.functions as JSONObject[])?.length ||
		(result.functionDeclarations as JSONObject[])?.length ||
		0;
	if (toolCount > 0) {
		convertTools(result, sourceFormat, targetFormat);
	}

	// Clean up format-specific fields
	cleanupIncompatibleFields(result, targetFormat);

	return result;
}

// MARK: - Model Detection

/**
 * Check if a model name is a Claude model
 */
export function isClaudeModel(modelName: string): boolean {
	const claudeKeywords = ["claude", "opus", "haiku", "sonnet"];
	const lowerModel = modelName.toLowerCase();
	return claudeKeywords.some((keyword) => lowerModel.includes(keyword));
}

// MARK: - Format Detection

/**
 * Detect the API format from request body structure
 */
export function detectFormat(body: JSONObject): APIFormat {
	// Check for Google-specific fields (most distinctive)
	if (body.contents !== undefined || body.generationConfig !== undefined) {
		return APIFormat.GOOGLE;
	}

	// Check for Anthropic-specific fields
	if (typeof body.system === "string" && body.system.length > 0) {
		const messages = body.messages as JSONObject[] | undefined;
		if (messages?.length) {
			const firstMessage = messages[0];
			if (Array.isArray(firstMessage?.content)) {
				return APIFormat.ANTHROPIC;
			}
		}
		return APIFormat.ANTHROPIC;
	}

	// Check message content format for Anthropic (array of blocks)
	const messages = body.messages as JSONObject[] | undefined;
	if (messages?.length) {
		const firstMessage = messages[0];
		const content = firstMessage?.content;
		if (Array.isArray(content)) {
			for (const block of content as JSONObject[]) {
				const type = block.type as string | undefined;
				if (
					type === "tool_use" ||
					type === "tool_result" ||
					type === "thinking"
				) {
					return APIFormat.ANTHROPIC;
				}
			}
			return APIFormat.ANTHROPIC;
		}
	}

	// Default to OpenAI format (most common)
	return APIFormat.OPENAI;
}

// MARK: - Message Conversion

/**
 * Convert messages array between formats
 */
function convertMessages(
	messages: JSONObject[],
	sourceFormat: APIFormat,
	targetFormat: APIFormat,
): JSONObject[] {
	// Special handling: Anthropic → OpenAI
	if (
		sourceFormat === APIFormat.ANTHROPIC &&
		targetFormat === APIFormat.OPENAI
	) {
		return convertAnthropicMessagesToOpenAI(messages);
	}

	// Special handling: OpenAI → Anthropic
	if (
		sourceFormat === APIFormat.OPENAI &&
		targetFormat === APIFormat.ANTHROPIC
	) {
		return convertOpenAIMessagesToAnthropic(messages);
	}

	if (sourceFormat === targetFormat) {
		return messages;
	}

	return messages.map((message) => {
		const converted = { ...message };

		// Convert role names
		if (typeof message.role === "string") {
			converted.role = convertRole(message.role, sourceFormat, targetFormat);
		}

		// Convert content format
		if (message.content !== undefined) {
			converted.content = convertContent(
				message.content,
				sourceFormat,
				targetFormat,
			);
		}

		// Handle tool-related fields in messages
		convertToolFieldsInMessage(converted, sourceFormat, targetFormat);

		return converted;
	});
}

// MARK: - Anthropic to OpenAI Message Conversion

/**
 * Convert Anthropic messages to OpenAI format (handles tool_use and tool_result)
 */
function convertAnthropicMessagesToOpenAI(
	messages: JSONObject[],
): JSONObject[] {
	const result: JSONObject[] = [];

	for (const message of messages) {
		const role = message.role as string | undefined;
		if (!role) {
			result.push(message);
			continue;
		}

		if (role === "assistant") {
			result.push(convertAnthropicAssistantToOpenAI(message));
			continue;
		}

		if (role === "user") {
			result.push(...convertAnthropicUserToOpenAI(message));
			continue;
		}

		// Other messages: simple content conversion
		const converted = { ...message };
		if (message.content !== undefined) {
			converted.content = convertAnthropicContentToOpenAI(message.content);
		}
		result.push(converted);
	}

	return result;
}

/**
 * Convert Anthropic assistant message to OpenAI format
 */
function convertAnthropicAssistantToOpenAI(message: JSONObject): JSONObject {
	const converted = { ...message };
	const content = message.content;

	if (!Array.isArray(content)) {
		if (typeof content === "string") {
			converted.content = content;
		}
		return converted;
	}

	const textParts: string[] = [];
	const toolCalls: JSONObject[] = [];

	for (const block of content as JSONObject[]) {
		const type = block.type as string | undefined;
		if (!type) continue;

		switch (type) {
			case "text":
				if (typeof block.text === "string") {
					textParts.push(block.text);
				}
				break;
			case "tool_use": {
				const id = block.id as string | undefined;
				const name = block.name as string | undefined;
				const input = block.input as JSONObject | undefined;
				if (id && name && input) {
					toolCalls.push({
						id,
						type: "function",
						function: {
							name,
							arguments: JSON.stringify(input),
						},
					});
				}
				break;
			}
			case "thinking":
				// Skip thinking blocks for OpenAI
				continue;
			default:
				if (typeof block.text === "string") {
					textParts.push(block.text);
				}
		}
	}

	// Set content
	if (textParts.length === 0) {
		converted.content = toolCalls.length > 0 ? null : "";
	} else {
		converted.content = textParts.join("\n");
	}

	// Add tool_calls if present
	if (toolCalls.length > 0) {
		converted.tool_calls = toolCalls;
	}

	return converted;
}

/**
 * Convert Anthropic user message to OpenAI format
 */
function convertAnthropicUserToOpenAI(message: JSONObject): JSONObject[] {
	const content = message.content;
	if (!Array.isArray(content)) {
		return [message];
	}

	const textParts: string[] = [];

	for (const block of content as JSONObject[]) {
		const type = block.type as string | undefined;
		if (!type) continue;

		switch (type) {
			case "text":
				if (typeof block.text === "string") {
					textParts.push(block.text);
				}
				break;
			case "tool_result": {
				const toolUseId = block.tool_use_id as string | undefined;
				if (toolUseId) {
					let resultContent: string;
					if (typeof block.content === "string") {
						resultContent = block.content;
					} else if (Array.isArray(block.content)) {
						resultContent = (block.content as JSONObject[])
							.map((b) => (typeof b.text === "string" ? b.text : ""))
							.filter((t) => t)
							.join("\n");
					} else {
						resultContent = "";
					}
					textParts.push(`[Tool Result (id: ${toolUseId})]\n${resultContent}`);
				}
				break;
			}
			default:
				if (typeof block.text === "string") {
					textParts.push(block.text);
				}
		}
	}

	if (textParts.length === 0) {
		return [{ role: "user", content: "" }];
	}

	return [{ role: "user", content: textParts.join("\n\n") }];
}

// MARK: - OpenAI to Anthropic Message Conversion

/**
 * Convert OpenAI messages to Anthropic format
 */
function convertOpenAIMessagesToAnthropic(
	messages: JSONObject[],
): JSONObject[] {
	const result: JSONObject[] = [];
	let pendingToolResults: JSONObject[] = [];

	for (const message of messages) {
		const role = message.role as string | undefined;
		if (!role) {
			result.push(message);
			continue;
		}

		// Collect tool responses to merge into user message
		if (role === "tool") {
			const toolCallId = message.tool_call_id as string | undefined;
			const content = message.content as string | undefined;
			if (toolCallId && content) {
				pendingToolResults.push({
					type: "tool_result",
					tool_use_id: toolCallId,
					content,
				});
			}
			continue;
		}

		// Flush pending tool results before processing next non-tool message
		if (pendingToolResults.length > 0) {
			result.push({
				role: "user",
				content: pendingToolResults,
			});
			pendingToolResults = [];
		}

		if (role === "assistant") {
			result.push(convertOpenAIAssistantToAnthropic(message));
			continue;
		}

		// Other messages: convert content to Anthropic format
		const converted = { ...message };
		if (message.content !== undefined) {
			converted.content = convertOpenAIContentToAnthropic(message.content);
		}
		result.push(converted);
	}

	// Flush any remaining tool results
	if (pendingToolResults.length > 0) {
		result.push({
			role: "user",
			content: pendingToolResults,
		});
	}

	return result;
}

/**
 * Convert OpenAI assistant message to Anthropic format
 */
function convertOpenAIAssistantToAnthropic(message: JSONObject): JSONObject {
	const converted = { ...message };
	const contentBlocks: JSONObject[] = [];

	// Convert existing content to text block
	if (typeof message.content === "string" && message.content.length > 0) {
		contentBlocks.push({ type: "text", text: message.content });
	} else if (Array.isArray(message.content)) {
		contentBlocks.push(...(message.content as JSONObject[]));
	}

	// Convert tool_calls to tool_use blocks
	const toolCalls = message.tool_calls as JSONObject[] | undefined;
	if (toolCalls) {
		for (const call of toolCalls) {
			const func = call.function as JSONObject | undefined;
			if (func) {
				const name = func.name as string | undefined;
				const argsString = func.arguments as string | undefined;
				if (name && argsString) {
					try {
						const args = JSON.parse(argsString);
						contentBlocks.push({
							type: "tool_use",
							id: (call.id as string) || randomUUID(),
							name,
							input: args,
						});
					} catch {
						// Skip invalid JSON
					}
				}
			}
		}
		converted.tool_calls = undefined;
	}

	converted.content = contentBlocks;
	return converted;
}

/**
 * Convert role name between formats
 */
function convertRole(role: string, _from: APIFormat, to: APIFormat): string {
	// Normalize to common format first
	let normalized: string;
	switch (role.toLowerCase()) {
		case "model":
			normalized = "assistant";
			break;
		case "system":
		case "user":
		case "assistant":
		case "tool":
			normalized = role.toLowerCase();
			break;
		default:
			normalized = role;
	}

	// Convert to target format
	if (normalized === "assistant" && to === APIFormat.GOOGLE) {
		return "model";
	}
	return normalized;
}

/**
 * Convert content between formats
 */
function convertContent(
	content: JSONValue,
	sourceFormat: APIFormat,
	targetFormat: APIFormat,
): JSONValue {
	switch (`${sourceFormat}->${targetFormat}`) {
		case `${APIFormat.ANTHROPIC}->${APIFormat.OPENAI}`:
			return convertAnthropicContentToOpenAI(content);
		case `${APIFormat.OPENAI}->${APIFormat.ANTHROPIC}`:
			return convertOpenAIContentToAnthropic(content);
		case `${APIFormat.GOOGLE}->${APIFormat.OPENAI}`:
		case `${APIFormat.GOOGLE}->${APIFormat.ANTHROPIC}`:
			return convertGoogleContentToOpenAI(content);
		case `${APIFormat.OPENAI}->${APIFormat.GOOGLE}`:
		case `${APIFormat.ANTHROPIC}->${APIFormat.GOOGLE}`:
			return convertToGoogleContent(content);
		default:
			return cleanThinkingFromContent(content, targetFormat);
	}
}

// MARK: - Content Format Converters

/**
 * Convert Anthropic content blocks to OpenAI format
 */
function convertAnthropicContentToOpenAI(content: JSONValue): JSONValue {
	if (typeof content === "string") {
		return content;
	}

	if (!Array.isArray(content)) {
		return content;
	}

	const textParts: string[] = [];
	let hasNonTextContent = false;
	const nonTextBlocks: JSONObject[] = [];

	for (const block of content as JSONObject[]) {
		const type = block.type as string | undefined;
		if (!type) continue;

		switch (type) {
			case "text":
				if (typeof block.text === "string") {
					textParts.push(block.text);
				}
				break;
			case "thinking":
				// Skip thinking blocks
				continue;
			case "image": {
				hasNonTextContent = true;
				const source = block.source as JSONObject | undefined;
				if (source) {
					const mediaType = source.media_type as string;
					const data = source.data as string;
					if (mediaType && data) {
						nonTextBlocks.push({
							type: "image_url",
							image_url: { url: `data:${mediaType};base64,${data}` },
						});
					}
				}
				break;
			}
			case "tool_use":
			case "tool_result":
				hasNonTextContent = true;
				nonTextBlocks.push(block);
				break;
			default:
				hasNonTextContent = true;
				nonTextBlocks.push(block);
		}
	}

	// If only text content, return as string
	if (!hasNonTextContent && textParts.length > 0) {
		return textParts.join("\n");
	}

	// If has non-text content, return as OpenAI content array
	if (hasNonTextContent) {
		const result: JSONObject[] = [];
		if (textParts.length > 0) {
			result.push({ type: "text", text: textParts.join("\n") });
		}
		result.push(...nonTextBlocks);
		return result;
	}

	return textParts.join("\n");
}

/**
 * Convert OpenAI content to Anthropic format
 */
function convertOpenAIContentToAnthropic(content: JSONValue): JSONValue {
	if (typeof content === "string") {
		return [{ type: "text", text: content }];
	}

	if (!Array.isArray(content)) {
		return [{ type: "text", text: String(content) }];
	}

	return (content as JSONObject[])
		.map((block) => {
			const type = block.type as string | undefined;
			if (!type) return block;

			switch (type) {
				case "text":
					return block;
				case "image_url": {
					const imageUrl = block.image_url as JSONObject | undefined;
					const url = imageUrl?.url as string | undefined;
					if (url?.startsWith("data:")) {
						const match = url.match(/^data:([^;]+);base64,(.+)$/);
						if (match) {
							return {
								type: "image",
								source: {
									type: "base64",
									media_type: match[1],
									data: match[2],
								},
							};
						}
					}
					if (url) {
						return {
							type: "image",
							source: { type: "url", url },
						};
					}
					return null;
				}
				default:
					return block;
			}
		})
		.filter((b): b is JSONObject => b !== null);
}

/**
 * Convert Google parts to OpenAI format
 */
function convertGoogleContentToOpenAI(content: JSONValue): JSONValue {
	if (Array.isArray(content)) {
		const textParts: string[] = [];
		for (const part of content as JSONObject[]) {
			if (typeof part.text === "string") {
				textParts.push(part.text);
			}
		}
		return textParts.join("\n");
	}

	if (typeof content === "string") {
		return content;
	}

	return content;
}

/**
 * Convert content to Google parts format
 */
function convertToGoogleContent(content: JSONValue): JSONValue {
	if (typeof content === "string") {
		return [{ text: content }];
	}

	if (Array.isArray(content)) {
		return (content as JSONObject[])
			.map((block) => {
				if (typeof block.text === "string") {
					return { text: block.text };
				}
				if (block.type === "text" && typeof block.text === "string") {
					return { text: block.text };
				}
				return null;
			})
			.filter((b): b is { text: string } => b !== null);
	}

	return [{ text: String(content) }];
}

// MARK: - System Message Handling

/**
 * Convert system message between formats
 */
function convertSystemMessage(
	body: JSONObject,
	sourceFormat: APIFormat,
	targetFormat: APIFormat,
): void {
	let systemContent: string | null = null;

	// Extract system content from source format
	switch (sourceFormat) {
		case APIFormat.ANTHROPIC:
			if (typeof body.system === "string") {
				systemContent = body.system;
			}
			break;
		case APIFormat.OPENAI: {
			const messages = body.messages as JSONObject[] | undefined;
			if (messages) {
				const sysIdx = messages.findIndex((m) => m.role === "system");
				const sysMsg = sysIdx !== -1 ? messages[sysIdx] : undefined;
				if (sysMsg) {
					if (typeof sysMsg.content === "string") {
						systemContent = sysMsg.content;
					} else if (Array.isArray(sysMsg.content)) {
						const textBlock = (sysMsg.content as JSONObject[]).find(
							(b) => b.type === "text",
						);
						if (textBlock && typeof textBlock.text === "string") {
							systemContent = textBlock.text;
						}
					}
					if (targetFormat === APIFormat.ANTHROPIC) {
						messages.splice(sysIdx, 1);
						body.messages = messages;
					}
				}
			}
			break;
		}
		case APIFormat.GOOGLE: {
			const instruction = body.system_instruction as JSONObject | undefined;
			if (instruction) {
				const parts = instruction.parts as JSONObject[] | undefined;
				if (parts?.[0] && typeof parts[0].text === "string") {
					systemContent = parts[0].text;
				}
			}
			break;
		}
	}

	if (!systemContent) return;

	// Apply system content to target format
	switch (targetFormat) {
		case APIFormat.ANTHROPIC:
			body.system = systemContent;
			body.system_instruction = undefined;
			break;
		case APIFormat.OPENAI: {
			let messages = (body.messages as JSONObject[]) || [];
			const hasSystem = messages.some((m) => m.role === "system");
			if (!hasSystem) {
				messages = [{ role: "system", content: systemContent }, ...messages];
				body.messages = messages;
			}
			body.system = undefined;
			body.system_instruction = undefined;
			break;
		}
		case APIFormat.GOOGLE:
			body.system_instruction = { parts: [{ text: systemContent }] };
			body.system = undefined;
			break;
	}
}

// MARK: - Parameter Conversion

/**
 * Convert parameters to target provider format
 */
function convertParameters(body: JSONObject, targetProvider: AIProvider): void {
	const targetFormat = getApiFormat(targetProvider);

	// Collect all max tokens values
	const allMaxTokensParams = [
		"maxOutputTokens",
		"maxTokens",
		"max_tokens",
		"max_completion_tokens",
	];
	let maxTokensValue: number | null = null;

	for (const param of allMaxTokensParams) {
		const value = extractIntValue(body[param]);
		if (value !== null) {
			maxTokensValue = value;
			break;
		}
	}

	// Check generationConfig for Google format
	if (maxTokensValue === null) {
		const genConfig = body.generationConfig as JSONObject | undefined;
		if (genConfig) {
			for (const param of allMaxTokensParams) {
				const value = extractIntValue(genConfig[param]);
				if (value !== null) {
					maxTokensValue = value;
					break;
				}
			}
		}
	}

	// Remove all max tokens params
	for (const param of allMaxTokensParams) {
		delete body[param];
	}

	// Set target max tokens param
	if (maxTokensValue !== null) {
		body[getDefaultMaxTokensParam(targetFormat)] = maxTokensValue;
	}

	// Handle Google's generationConfig
	if (targetFormat === APIFormat.GOOGLE) {
		const genConfig = (body.generationConfig as JSONObject) || {};
		if (maxTokensValue !== null) {
			genConfig.maxOutputTokens = maxTokensValue;
		}
		if (body.temperature !== undefined) {
			genConfig.temperature = body.temperature;
			body.temperature = undefined;
		}
		if (body.topP !== undefined || body.top_p !== undefined) {
			genConfig.topP = body.topP ?? body.top_p;
			body.topP = undefined;
			body.top_p = undefined;
		}
		if (body.topK !== undefined || body.top_k !== undefined) {
			genConfig.topK = body.topK ?? body.top_k;
			body.topK = undefined;
			body.top_k = undefined;
		}
		if (Object.keys(genConfig).length > 0) {
			body.generationConfig = genConfig;
		}
	} else {
		body.generationConfig = undefined;
	}

	// Handle stop sequences
	convertStopSequences(body, targetFormat);

	// Validate and clean parameters
	validateParameters(body);
}

/**
 * Extract integer value from various number types
 */
function extractIntValue(value: JSONValue | undefined): number | null {
	if (value === undefined || value === null) return null;
	if (typeof value === "number" && value >= 1) return Math.floor(value);
	return null;
}

/**
 * Convert stop sequences between formats
 */
function convertStopSequences(body: JSONObject, targetFormat: APIFormat): void {
	const stopParams = ["stop", "stop_sequences", "stopSequences"];
	let stopValue: string[] | null = null;

	for (const param of stopParams) {
		const val = body[param];
		if (Array.isArray(val)) {
			stopValue = val as string[];
			delete body[param];
		} else if (typeof val === "string") {
			stopValue = [val];
			delete body[param];
		}
	}

	if (!stopValue || stopValue.length === 0) return;

	switch (targetFormat) {
		case APIFormat.OPENAI:
			body.stop = stopValue;
			break;
		case APIFormat.ANTHROPIC:
			body.stop_sequences = stopValue;
			break;
		case APIFormat.GOOGLE: {
			const genConfig = (body.generationConfig as JSONObject) || {};
			genConfig.stopSequences = stopValue;
			body.generationConfig = genConfig;
			break;
		}
	}
}

/**
 * Validate and clean invalid parameters
 */
export function validateParameters(body: JSONObject): void {
	// Temperature: 0-2
	if (body.temperature !== undefined) {
		const temp = body.temperature as number;
		if (temp < 0 || temp > 2) {
			body.temperature = undefined;
		}
	}

	// top_p/topP: 0-1
	for (const param of ["top_p", "topP"]) {
		if (body[param] !== undefined) {
			const val = body[param] as number;
			if (val < 0 || val > 1) {
				delete body[param];
			}
		}
	}

	// top_k/topK: >= 1
	for (const param of ["top_k", "topK"]) {
		if (body[param] !== undefined) {
			const val = body[param] as number;
			if (val < 1) {
				delete body[param];
			}
		}
	}
}

// MARK: - Tool Conversion

/**
 * Convert tool definitions between formats
 */
function convertTools(
	body: JSONObject,
	sourceFormat: APIFormat,
	targetFormat: APIFormat,
): void {
	if (sourceFormat === targetFormat) return;

	// Extract tools from source format
	let tools: JSONObject[] | null = null;

	if (Array.isArray(body.tools)) {
		tools = body.tools as JSONObject[];
	} else if (Array.isArray(body.functions)) {
		tools = (body.functions as JSONObject[]).map((f) => ({
			type: "function",
			function: f,
		}));
	} else if (Array.isArray(body.functionDeclarations)) {
		tools = (body.functionDeclarations as JSONObject[]).map((d) => ({
			type: "function",
			function: d,
		}));
	}

	if (!tools) return;

	// Remove all tool-related fields
	body.tools = undefined;
	body.functions = undefined;
	body.functionDeclarations = undefined;
	body.tool_choice = undefined;
	body.function_call = undefined;

	// Convert to target format
	switch (targetFormat) {
		case APIFormat.OPENAI:
		case APIFormat.ANTHROPIC:
			body.tools = tools;
			break;
		case APIFormat.GOOGLE: {
			const declarations = tools
				.map((t) => (t.function as JSONObject) || t)
				.filter((d): d is JSONObject => d !== null);
			body.functionDeclarations = declarations;
			break;
		}
	}
}

/**
 * Convert tool-related fields in individual messages
 */
function convertToolFieldsInMessage(
	message: JSONObject,
	sourceFormat: APIFormat,
	targetFormat: APIFormat,
): void {
	const toolCalls = message.tool_calls as JSONObject[] | undefined;

	// Handle tool_calls (OpenAI) → tool_use (Anthropic)
	if (toolCalls && targetFormat === APIFormat.ANTHROPIC) {
		const content = (message.content as JSONObject[]) || [];
		for (const call of toolCalls) {
			const func = call.function as JSONObject | undefined;
			if (func) {
				const name = func.name as string;
				const argsString = func.arguments as string;
				try {
					const args = JSON.parse(argsString);
					content.push({
						type: "tool_use",
						id: (call.id as string) || randomUUID(),
						name,
						input: args,
					});
				} catch {
					// Skip invalid JSON
				}
			}
		}
		message.content = content;
		message.tool_calls = undefined;
	}

	// Handle tool_use (Anthropic) → tool_calls (OpenAI)
	if (
		sourceFormat === APIFormat.ANTHROPIC &&
		targetFormat === APIFormat.OPENAI
	) {
		let content = message.content as JSONObject[] | undefined;
		if (Array.isArray(content)) {
			const newToolCalls: JSONObject[] = [];
			content = content.filter((block) => {
				if (block.type === "tool_use") {
					const name = block.name as string;
					const input = block.input as JSONObject;
					newToolCalls.push({
						id: (block.id as string) || randomUUID(),
						type: "function",
						function: {
							name,
							arguments: JSON.stringify(input),
						},
					});
					return false;
				}
				return true;
			});
			if (newToolCalls.length > 0) {
				message.tool_calls = newToolCalls;
			}
			message.content = content.length === 0 ? "" : content;
		}
	}
}

// MARK: - Cleanup

/**
 * Remove fields incompatible with target format
 */
function cleanupIncompatibleFields(
	body: JSONObject,
	targetFormat: APIFormat,
): void {
	switch (targetFormat) {
		case APIFormat.OPENAI:
			body.system = undefined;
			body.system_instruction = undefined;
			body.generationConfig = undefined;
			body.contents = undefined;
			break;
		case APIFormat.ANTHROPIC:
			body.system_instruction = undefined;
			body.generationConfig = undefined;
			body.contents = undefined;
			body.functions = undefined;
			body.function_call = undefined;
			break;
		case APIFormat.GOOGLE:
			body.system = undefined;
			body.max_tokens = undefined;
			body.max_completion_tokens = undefined;
			body.top_p = undefined;
			body.top_k = undefined;
			body.stop = undefined;
			body.stop_sequences = undefined;
			break;
	}
}

// MARK: - Thinking Block Handling

/**
 * Clean thinking blocks from request body
 */
export function cleanThinkingBlocksInBody(
	body: JSONObject,
	isClaudeModelTarget = false,
): void {
	const messages = body.messages as JSONObject[] | undefined;
	if (!Array.isArray(messages)) return;

	body.messages = messages.map((message) => {
		const content = message.content;
		if (!Array.isArray(content)) return message;

		const cleaned = { ...message };
		cleaned.content = (content as JSONObject[]).filter((block) => {
			const type = block.type as string | undefined;
			if (type !== "thinking") return true;

			if (isClaudeModelTarget) {
				const signature = block.signature as string | undefined;
				return signature && signature.length > 0;
			}
			return false;
		});
		return cleaned;
	});
}

/**
 * Clean thinking from content (for single content value)
 */
function cleanThinkingFromContent(
	content: JSONValue,
	targetFormat: APIFormat,
): JSONValue {
	if (!Array.isArray(content)) return content;

	return (content as JSONObject[]).filter((block) => {
		const type = block.type as string | undefined;
		if (type !== "thinking") return true;

		if (targetFormat === APIFormat.ANTHROPIC) {
			const signature = block.signature as string | undefined;
			return signature && signature.length > 0;
		}
		return false;
	});
}

// MARK: - Error Detection

/**
 * Check if response indicates an error that should trigger fallback
 */
export function shouldTriggerFallback(responseData: string): boolean {
	// Check HTTP status code
	const firstLine = responseData.split("\r\n")[0];
	if (firstLine) {
		const parts = firstLine.split(" ");
		const statusCode = parts[1];
		if (parts.length >= 2 && statusCode) {
			const code = Number.parseInt(statusCode, 10);
			if (!Number.isNaN(code)) {
				if ([429, 503, 500, 400, 401, 403, 422].includes(code)) {
					return true;
				}
				if (code >= 200 && code < 300) {
					return false;
				}
			}
		}
	}

	// Check error patterns in response body
	const lowercased = responseData.toLowerCase();
	const errorPatterns = [
		"quota exceeded",
		"rate limit",
		"limit reached",
		"no available account",
		"insufficient_quota",
		"resource_exhausted",
		"overloaded",
		"capacity",
		"too many requests",
		"throttl",
		"invalid_request",
		"bad request",
		"unsupported",
		"malformed",
		"validation error",
		"field required",
		"invalid value",
		"authentication",
		"unauthorized",
		"invalid api key",
		"access denied",
		"model not found",
		"model unavailable",
		"does not exist",
	];

	for (const pattern of errorPatterns) {
		if (lowercased.includes(pattern)) {
			return true;
		}
	}

	return false;
}
