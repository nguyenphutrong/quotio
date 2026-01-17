/**
 * OpenAI format translator
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
	ToolUseContent,
	ToolResultContent,
	StreamDelta,
	ToolDefinition,
} from "./types.js";

/**
 * OpenAI message format
 */
interface OpenAIMessage {
	role: "system" | "user" | "assistant" | "tool";
	content: string | OpenAIContentPart[] | null;
	name?: string;
	tool_calls?: OpenAIToolCall[];
	tool_call_id?: string;
}

interface OpenAIContentPart {
	type: "text" | "image_url";
	text?: string;
	image_url?: { url: string; detail?: string };
}

interface OpenAIToolCall {
	id: string;
	type: "function";
	function: {
		name: string;
		arguments: string;
	};
}

interface OpenAITool {
	type: "function";
	function: {
		name: string;
		description?: string;
		parameters?: Record<string, unknown>;
	};
}

interface OpenAIRequest {
	model: string;
	messages: OpenAIMessage[];
	max_tokens?: number;
	temperature?: number;
	top_p?: number;
	stop?: string[];
	tools?: OpenAITool[];
	stream?: boolean;
}

interface OpenAIChoice {
	index: number;
	message: OpenAIMessage;
	finish_reason: "stop" | "length" | "tool_calls" | null;
}

interface OpenAIResponse {
	id: string;
	object: string;
	created: number;
	model: string;
	choices: OpenAIChoice[];
	usage?: {
		prompt_tokens: number;
		completion_tokens: number;
		total_tokens: number;
	};
}

interface OpenAIStreamChunk {
	id: string;
	object: string;
	created: number;
	model: string;
	choices: {
		index: number;
		delta: {
			role?: string;
			content?: string | null;
			tool_calls?: Array<{
				index: number;
				id?: string;
				type?: string;
				function?: {
					name?: string;
					arguments?: string;
				};
			}>;
		};
		finish_reason: string | null;
	}[];
}

export class OpenAITranslator implements Translator {
	format(): ApiFormat {
		return "openai";
	}

	parseRequest(payload: Uint8Array): UnifiedRequest {
		const text = new TextDecoder().decode(payload);
		const req = JSON.parse(text) as OpenAIRequest;

		const messages: UnifiedMessage[] = [];
		let systemPrompt: string | undefined;

		for (const msg of req.messages) {
			if (msg.role === "system") {
				systemPrompt = typeof msg.content === "string" ? msg.content : "";
				continue;
			}

			messages.push(this.parseMessage(msg));
		}

		return {
			model: req.model,
			messages,
			systemPrompt,
			maxTokens: req.max_tokens,
			temperature: req.temperature,
			topP: req.top_p,
			stopSequences: req.stop,
			tools: req.tools?.map((t) => this.parseTool(t)),
			stream: req.stream,
		};
	}

	buildRequest(request: UnifiedRequest): Uint8Array {
		const messages: OpenAIMessage[] = [];

		// Add system message if present
		if (request.systemPrompt) {
			messages.push({
				role: "system",
				content: request.systemPrompt,
			});
		}

		// Convert unified messages to OpenAI format
		for (const msg of request.messages) {
			messages.push(this.buildMessage(msg));
		}

		const req: OpenAIRequest = {
			model: request.model,
			messages,
			max_tokens: request.maxTokens,
			temperature: request.temperature,
			top_p: request.topP,
			stop: request.stopSequences,
			tools: request.tools?.map((t) => this.buildTool(t)),
			stream: request.stream,
		};

		// Remove undefined fields
		const cleaned = JSON.parse(JSON.stringify(req)) as OpenAIRequest;
		return new TextEncoder().encode(JSON.stringify(cleaned));
	}

	parseResponse(payload: Uint8Array): UnifiedResponse {
		const text = new TextDecoder().decode(payload);
		const res = JSON.parse(text) as OpenAIResponse;

		const choice = res.choices[0];
		const content = this.parseResponseContent(choice?.message);

		return {
			id: res.id,
			model: res.model,
			content,
			stopReason: this.mapStopReason(choice?.finish_reason),
			usage: res.usage
				? {
						inputTokens: res.usage.prompt_tokens,
						outputTokens: res.usage.completion_tokens,
						totalTokens: res.usage.total_tokens,
					}
				: undefined,
		};
	}

	buildResponse(response: UnifiedResponse): Uint8Array {
		const message = this.buildResponseMessage(response.content);

		const res: OpenAIResponse = {
			id: response.id,
			object: "chat.completion",
			created: Math.floor(Date.now() / 1000),
			model: response.model,
			choices: [
				{
					index: 0,
					message,
					finish_reason: this.mapStopReasonToOpenAI(response.stopReason),
				},
			],
			usage: response.usage
				? {
						prompt_tokens: response.usage.inputTokens,
						completion_tokens: response.usage.outputTokens,
						total_tokens: response.usage.totalTokens,
					}
				: undefined,
		};

		return new TextEncoder().encode(JSON.stringify(res));
	}

	parseStreamChunk(chunk: string): StreamDelta | null {
		// Handle SSE format
		const lines = chunk.split("\n");
		for (const line of lines) {
			if (line.startsWith("data: ")) {
				const data = line.slice(6).trim();
				if (data === "[DONE]") {
					return { type: "message_stop" };
				}

				try {
					const parsed = JSON.parse(data) as OpenAIStreamChunk;
					const choice = parsed.choices[0];

					if (choice?.delta?.content) {
						return {
							type: "content_block_delta",
							index: 0,
							delta: {
								type: "text_delta",
								text: choice.delta.content,
							},
						};
					}

					if (choice?.finish_reason) {
						return { type: "message_stop" };
					}
				} catch {
					// Skip invalid JSON
				}
			}
		}
		return null;
	}

	buildStreamChunk(delta: StreamDelta): string {
		if (delta.type === "message_stop") {
			return "data: [DONE]\n\n";
		}

		if (delta.type === "content_block_delta" && delta.delta?.text) {
			const chunk: OpenAIStreamChunk = {
				id: "chatcmpl-" + Date.now(),
				object: "chat.completion.chunk",
				created: Math.floor(Date.now() / 1000),
				model: "",
				choices: [
					{
						index: 0,
						delta: { content: delta.delta.text },
						finish_reason: null,
					},
				],
			};
			return `data: ${JSON.stringify(chunk)}\n\n`;
		}

		return "";
	}

	private parseMessage(msg: OpenAIMessage): UnifiedMessage {
		const content: ContentBlock[] = [];

		if (typeof msg.content === "string" && msg.content) {
			content.push({ type: "text", text: msg.content });
		} else if (Array.isArray(msg.content)) {
			for (const part of msg.content) {
				if (part.type === "text" && part.text) {
					content.push({ type: "text", text: part.text });
				} else if (part.type === "image_url" && part.image_url?.url) {
					content.push({
						type: "image",
						source: {
							type: "url",
							url: part.image_url.url,
						},
					});
				}
			}
		}

		// Handle tool calls
		if (msg.tool_calls) {
			for (const call of msg.tool_calls) {
				content.push({
					type: "tool_use",
					id: call.id,
					name: call.function.name,
					input: JSON.parse(call.function.arguments || "{}"),
				});
			}
		}

		// Handle tool results
		if (msg.role === "tool" && msg.tool_call_id) {
			return {
				role: "tool",
				content: [
					{
						type: "tool_result",
						toolUseId: msg.tool_call_id,
						content: typeof msg.content === "string" ? msg.content : "",
					},
				],
			};
		}

		return {
			role: msg.role === "tool" ? "tool" : msg.role,
			content: content.length === 1 && content[0].type === "text" 
				? (content[0] as TextContent).text 
				: content,
			name: msg.name,
		};
	}

	private buildMessage(msg: UnifiedMessage): OpenAIMessage {
		// Handle tool results
		if (msg.role === "tool" && Array.isArray(msg.content)) {
			const toolResult = msg.content.find((c): c is ToolResultContent => c.type === "tool_result");
			if (toolResult) {
				return {
					role: "tool",
					content: typeof toolResult.content === "string" ? toolResult.content : JSON.stringify(toolResult.content),
					tool_call_id: toolResult.toolUseId,
				};
			}
		}

		// Handle simple string content
		if (typeof msg.content === "string") {
			return {
				role: msg.role === "tool" ? "tool" : msg.role,
				content: msg.content,
				name: msg.name,
			};
		}

		// Handle complex content
		const contentParts: OpenAIContentPart[] = [];
		const toolCalls: OpenAIToolCall[] = [];

		for (const block of msg.content) {
			if (block.type === "text") {
				contentParts.push({ type: "text", text: block.text });
			} else if (block.type === "image") {
				const url = block.source.type === "url" 
					? block.source.url 
					: `data:${block.source.mediaType};base64,${block.source.data}`;
				if (url) {
					contentParts.push({ type: "image_url", image_url: { url } });
				}
			} else if (block.type === "tool_use") {
				toolCalls.push({
					id: block.id,
					type: "function",
					function: {
						name: block.name,
						arguments: JSON.stringify(block.input),
					},
				});
			}
		}

		const message: OpenAIMessage = {
			role: msg.role === "tool" ? "tool" : msg.role,
			content: contentParts.length > 0 ? contentParts : null,
			name: msg.name,
		};

		if (toolCalls.length > 0) {
			message.tool_calls = toolCalls;
		}

		return message;
	}

	private parseResponseContent(msg?: OpenAIMessage): ContentBlock[] {
		if (!msg) return [];

		const content: ContentBlock[] = [];

		if (typeof msg.content === "string" && msg.content) {
			content.push({ type: "text", text: msg.content });
		}

		if (msg.tool_calls) {
			for (const call of msg.tool_calls) {
				content.push({
					type: "tool_use",
					id: call.id,
					name: call.function.name,
					input: JSON.parse(call.function.arguments || "{}"),
				});
			}
		}

		return content;
	}

	private buildResponseMessage(content: ContentBlock[]): OpenAIMessage {
		const textParts: string[] = [];
		const toolCalls: OpenAIToolCall[] = [];

		for (const block of content) {
			if (block.type === "text") {
				textParts.push(block.text);
			} else if (block.type === "tool_use") {
				toolCalls.push({
					id: block.id,
					type: "function",
					function: {
						name: block.name,
						arguments: JSON.stringify(block.input),
					},
				});
			}
		}

		const message: OpenAIMessage = {
			role: "assistant",
			content: textParts.join("") || null,
		};

		if (toolCalls.length > 0) {
			message.tool_calls = toolCalls;
		}

		return message;
	}

	private parseTool(tool: OpenAITool): ToolDefinition {
		return {
			name: tool.function.name,
			description: tool.function.description,
			inputSchema: tool.function.parameters ?? {},
		};
	}

	private buildTool(tool: ToolDefinition): OpenAITool {
		return {
			type: "function",
			function: {
				name: tool.name,
				description: tool.description,
				parameters: tool.inputSchema,
			},
		};
	}

	private mapStopReason(
		reason?: "stop" | "length" | "tool_calls" | null,
	): UnifiedResponse["stopReason"] {
		switch (reason) {
			case "stop":
				return "end_turn";
			case "length":
				return "max_tokens";
			case "tool_calls":
				return "tool_use";
			default:
				return undefined;
		}
	}

	private mapStopReasonToOpenAI(
		reason?: UnifiedResponse["stopReason"],
	): "stop" | "length" | "tool_calls" | null {
		switch (reason) {
			case "end_turn":
			case "stop_sequence":
				return "stop";
			case "max_tokens":
				return "length";
			case "tool_use":
				return "tool_calls";
			default:
				return null;
		}
	}
}
