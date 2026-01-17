/**
 * Anthropic (Claude) format translator
 * @packageDocumentation
 */

import type {
	Translator,
	ApiFormat,
	UnifiedRequest,
	UnifiedResponse,
	UnifiedMessage,
	ContentBlock,
	TextContent,
	ImageContent,
	ToolUseContent,
	ToolResultContent,
	StreamDelta,
	ToolDefinition,
} from "./types.js";

/**
 * Anthropic content block types
 */
interface AnthropicTextBlock {
	type: "text";
	text: string;
}

interface AnthropicImageBlock {
	type: "image";
	source: {
		type: "base64";
		media_type: string;
		data: string;
	};
}

interface AnthropicToolUseBlock {
	type: "tool_use";
	id: string;
	name: string;
	input: Record<string, unknown>;
}

interface AnthropicToolResultBlock {
	type: "tool_result";
	tool_use_id: string;
	content: string | AnthropicContentBlock[];
	is_error?: boolean;
}

type AnthropicContentBlock =
	| AnthropicTextBlock
	| AnthropicImageBlock
	| AnthropicToolUseBlock
	| AnthropicToolResultBlock;

interface AnthropicMessage {
	role: "user" | "assistant";
	content: string | AnthropicContentBlock[];
}

interface AnthropicTool {
	name: string;
	description?: string;
	input_schema: Record<string, unknown>;
}

interface AnthropicRequest {
	model: string;
	messages: AnthropicMessage[];
	system?: string;
	max_tokens: number;
	temperature?: number;
	top_p?: number;
	stop_sequences?: string[];
	tools?: AnthropicTool[];
	stream?: boolean;
	metadata?: Record<string, unknown>;
}

interface AnthropicResponse {
	id: string;
	type: "message";
	role: "assistant";
	model: string;
	content: AnthropicContentBlock[];
	stop_reason: "end_turn" | "max_tokens" | "stop_sequence" | "tool_use" | null;
	stop_sequence?: string;
	usage: {
		input_tokens: number;
		output_tokens: number;
	};
}

interface AnthropicStreamEvent {
	type: string;
	index?: number;
	content_block?: AnthropicContentBlock;
	delta?: {
		type: string;
		text?: string;
		partial_json?: string;
		stop_reason?: string;
	};
	message?: Partial<AnthropicResponse>;
	usage?: {
		input_tokens?: number;
		output_tokens?: number;
	};
}

export class AnthropicTranslator implements Translator {
	format(): ApiFormat {
		return "anthropic";
	}

	parseRequest(payload: Uint8Array): UnifiedRequest {
		const text = new TextDecoder().decode(payload);
		const req = JSON.parse(text) as AnthropicRequest;

		const messages: UnifiedMessage[] = req.messages.map((msg) =>
			this.parseMessage(msg),
		);

		return {
			model: req.model,
			messages,
			systemPrompt: req.system,
			maxTokens: req.max_tokens,
			temperature: req.temperature,
			topP: req.top_p,
			stopSequences: req.stop_sequences,
			tools: req.tools?.map((t) => this.parseTool(t)),
			stream: req.stream,
			metadata: req.metadata,
		};
	}

	buildRequest(request: UnifiedRequest): Uint8Array {
		const messages: AnthropicMessage[] = request.messages.map((msg) =>
			this.buildMessage(msg),
		);

		const req: AnthropicRequest = {
			model: request.model,
			messages,
			system: request.systemPrompt,
			max_tokens: request.maxTokens ?? 4096,
			temperature: request.temperature,
			top_p: request.topP,
			stop_sequences: request.stopSequences,
			tools: request.tools?.map((t) => this.buildTool(t)),
			stream: request.stream,
			metadata: request.metadata,
		};

		// Remove undefined fields
		const cleaned = JSON.parse(JSON.stringify(req)) as AnthropicRequest;
		return new TextEncoder().encode(JSON.stringify(cleaned));
	}

	parseResponse(payload: Uint8Array): UnifiedResponse {
		const text = new TextDecoder().decode(payload);
		const res = JSON.parse(text) as AnthropicResponse;

		return {
			id: res.id,
			model: res.model,
			content: res.content.map((block) => this.parseContentBlock(block)),
			stopReason: res.stop_reason ?? undefined,
			usage: {
				inputTokens: res.usage.input_tokens,
				outputTokens: res.usage.output_tokens,
				totalTokens: res.usage.input_tokens + res.usage.output_tokens,
			},
		};
	}

	buildResponse(response: UnifiedResponse): Uint8Array {
		const content: AnthropicContentBlock[] = response.content.map((block) =>
			this.buildContentBlock(block),
		);

		const res: AnthropicResponse = {
			id: response.id,
			type: "message",
			role: "assistant",
			model: response.model,
			content,
			stop_reason: response.stopReason ?? null,
			usage: {
				input_tokens: response.usage?.inputTokens ?? 0,
				output_tokens: response.usage?.outputTokens ?? 0,
			},
		};

		return new TextEncoder().encode(JSON.stringify(res));
	}

	parseStreamChunk(chunk: string): StreamDelta | null {
		// Handle SSE format
		const lines = chunk.split("\n");
		for (const line of lines) {
			if (line.startsWith("data: ")) {
				const data = line.slice(6).trim();
				if (!data) continue;

				try {
					const event = JSON.parse(data) as AnthropicStreamEvent;
					return this.parseStreamEvent(event);
				} catch {
					// Skip invalid JSON
				}
			}
		}
		return null;
	}

	buildStreamChunk(delta: StreamDelta): string {
		const event: AnthropicStreamEvent = {
			type: delta.type,
			index: delta.index,
		};

		if (delta.type === "content_block_delta" && delta.delta) {
			event.delta = {
				type: delta.delta.type,
				text: delta.delta.text,
				partial_json: delta.delta.partialJson,
			};
		}

		if (delta.contentBlock) {
			event.content_block = this.buildContentBlock(delta.contentBlock);
		}

		return `event: ${delta.type}\ndata: ${JSON.stringify(event)}\n\n`;
	}

	private parseMessage(msg: AnthropicMessage): UnifiedMessage {
		if (typeof msg.content === "string") {
			return {
				role: msg.role,
				content: msg.content,
			};
		}

		return {
			role: msg.role,
			content: msg.content.map((block) => this.parseContentBlock(block)),
		};
	}

	private buildMessage(msg: UnifiedMessage): AnthropicMessage {
		if (typeof msg.content === "string") {
			return {
				role: msg.role === "system" ? "user" : msg.role === "tool" ? "user" : msg.role,
				content: msg.content,
			};
		}

		return {
			role: msg.role === "system" ? "user" : msg.role === "tool" ? "user" : msg.role,
			content: msg.content.map((block) => this.buildContentBlock(block)),
		};
	}

	private parseContentBlock(block: AnthropicContentBlock): ContentBlock {
		switch (block.type) {
			case "text":
				return { type: "text", text: block.text };

			case "image":
				return {
					type: "image",
					source: {
						type: "base64",
						mediaType: block.source.media_type,
						data: block.source.data,
					},
				};

			case "tool_use":
				return {
					type: "tool_use",
					id: block.id,
					name: block.name,
					input: block.input,
				};

			case "tool_result":
				return {
					type: "tool_result",
					toolUseId: block.tool_use_id,
					content:
						typeof block.content === "string"
							? block.content
							: block.content.map((b) => this.parseContentBlock(b)),
					isError: block.is_error,
				};
		}
	}

	private buildContentBlock(block: ContentBlock): AnthropicContentBlock {
		switch (block.type) {
			case "text":
				return { type: "text", text: block.text };

			case "image":
				return {
					type: "image",
					source: {
						type: "base64",
						media_type: block.source.mediaType ?? "image/png",
						data: block.source.data ?? "",
					},
				};

			case "tool_use":
				return {
					type: "tool_use",
					id: block.id,
					name: block.name,
					input: block.input,
				};

			case "tool_result":
				return {
					type: "tool_result",
					tool_use_id: block.toolUseId,
					content:
						typeof block.content === "string"
							? block.content
							: block.content.map((b) => this.buildContentBlock(b)),
					is_error: block.isError,
				};
		}
	}

	private parseTool(tool: AnthropicTool): ToolDefinition {
		return {
			name: tool.name,
			description: tool.description,
			inputSchema: tool.input_schema,
		};
	}

	private buildTool(tool: ToolDefinition): AnthropicTool {
		return {
			name: tool.name,
			description: tool.description,
			input_schema: tool.inputSchema,
		};
	}

	private parseStreamEvent(event: AnthropicStreamEvent): StreamDelta | null {
		switch (event.type) {
			case "message_start":
				return {
					type: "message_start",
					message: event.message
						? {
								id: event.message.id,
								model: event.message.model,
								content: [],
							}
						: undefined,
				};

			case "content_block_start":
				return {
					type: "content_block_delta",
					index: event.index,
					contentBlock: event.content_block
						? this.parseContentBlock(event.content_block)
						: undefined,
				};

			case "content_block_delta":
				if (event.delta?.type === "text_delta") {
					return {
						type: "content_block_delta",
						index: event.index,
						delta: {
							type: "text_delta",
							text: event.delta.text,
						},
					};
				}
				if (event.delta?.type === "input_json_delta") {
					return {
						type: "content_block_delta",
						index: event.index,
						delta: {
							type: "input_json_delta",
							partialJson: event.delta.partial_json,
						},
					};
				}
				return null;

			case "message_delta":
				return {
					type: "message_delta",
					usage: event.usage
						? {
								inputTokens: event.usage.input_tokens ?? 0,
								outputTokens: event.usage.output_tokens ?? 0,
								totalTokens:
									(event.usage.input_tokens ?? 0) +
									(event.usage.output_tokens ?? 0),
							}
						: undefined,
				};

			case "message_stop":
				return { type: "message_stop" };

			default:
				return null;
		}
	}
}
