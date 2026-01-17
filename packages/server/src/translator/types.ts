/**
 * Translator types for format conversion between providers
 * @packageDocumentation
 */

/**
 * Supported API formats
 */
export type ApiFormat = "openai" | "anthropic" | "gemini";

/**
 * Role in a conversation
 */
export type MessageRole = "system" | "user" | "assistant" | "tool";

/**
 * Text content block
 */
export interface TextContent {
	type: "text";
	text: string;
}

/**
 * Image content block
 */
export interface ImageContent {
	type: "image";
	source: {
		type: "base64" | "url";
		mediaType?: string;
		data?: string;
		url?: string;
	};
}

/**
 * Tool use content block
 */
export interface ToolUseContent {
	type: "tool_use";
	id: string;
	name: string;
	input: Record<string, unknown>;
}

/**
 * Tool result content block
 */
export interface ToolResultContent {
	type: "tool_result";
	toolUseId: string;
	content: string | ContentBlock[];
	isError?: boolean;
}

/**
 * Content block union type
 */
export type ContentBlock =
	| TextContent
	| ImageContent
	| ToolUseContent
	| ToolResultContent;

/**
 * Unified message format
 */
export interface UnifiedMessage {
	role: MessageRole;
	content: string | ContentBlock[];
	name?: string;
}

/**
 * Tool definition
 */
export interface ToolDefinition {
	name: string;
	description?: string;
	inputSchema: Record<string, unknown>;
}

/**
 * Unified request format (internal representation)
 */
export interface UnifiedRequest {
	model: string;
	messages: UnifiedMessage[];
	systemPrompt?: string;
	maxTokens?: number;
	temperature?: number;
	topP?: number;
	stopSequences?: string[];
	tools?: ToolDefinition[];
	stream?: boolean;
	metadata?: Record<string, unknown>;
}

/**
 * Usage statistics
 */
export interface UsageStats {
	inputTokens: number;
	outputTokens: number;
	totalTokens: number;
}

/**
 * Unified response format
 */
export interface UnifiedResponse {
	id: string;
	model: string;
	content: ContentBlock[];
	stopReason?: "end_turn" | "max_tokens" | "stop_sequence" | "tool_use";
	usage?: UsageStats;
}

/**
 * Streaming delta
 */
export interface StreamDelta {
	type: "content_block_delta" | "message_delta" | "message_start" | "message_stop";
	index?: number;
	delta?: {
		type: "text_delta" | "input_json_delta";
		text?: string;
		partialJson?: string;
	};
	contentBlock?: ContentBlock;
	message?: Partial<UnifiedResponse>;
	usage?: UsageStats;
}

/**
 * Translator interface for format conversion
 */
export interface Translator {
	/**
	 * Format identifier
	 */
	format(): ApiFormat;

	/**
	 * Parse raw request bytes to unified format
	 */
	parseRequest(payload: Uint8Array): UnifiedRequest;

	/**
	 * Build provider-specific request from unified format
	 */
	buildRequest(request: UnifiedRequest): Uint8Array;

	/**
	 * Parse provider response to unified format
	 */
	parseResponse(payload: Uint8Array): UnifiedResponse;

	/**
	 * Build provider-specific response from unified format
	 */
	buildResponse(response: UnifiedResponse): Uint8Array;

	/**
	 * Parse streaming chunk
	 */
	parseStreamChunk?(chunk: string): StreamDelta | null;

	/**
	 * Build streaming chunk
	 */
	buildStreamChunk?(delta: StreamDelta): string;
}

/**
 * Translation result
 */
export interface TranslationResult {
	payload: Uint8Array;
	format: ApiFormat;
}
