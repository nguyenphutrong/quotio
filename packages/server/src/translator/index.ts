/**
 * Translator module exports
 * @packageDocumentation
 */

export type {
	ApiFormat,
	MessageRole,
	TextContent,
	ImageContent,
	ToolUseContent,
	ToolResultContent,
	ContentBlock,
	UnifiedMessage,
	ToolDefinition,
	UnifiedRequest,
	UnifiedResponse,
	UsageStats,
	StreamDelta,
	Translator,
	TranslationResult,
} from "./types.js";

export { OpenAITranslator } from "./openai.js";
export { AnthropicTranslator } from "./anthropic.js";

import type { ApiFormat, Translator, TranslationResult, UnifiedRequest } from "./types.js";
import { OpenAITranslator } from "./openai.js";
import { AnthropicTranslator } from "./anthropic.js";

/**
 * Translator registry for format conversion
 */
export class TranslatorRegistry {
	private translators: Map<ApiFormat, Translator> = new Map();

	constructor() {
		// Register default translators
		this.register(new OpenAITranslator());
		this.register(new AnthropicTranslator());
	}

	/**
	 * Register a translator
	 */
	register(translator: Translator): void {
		this.translators.set(translator.format(), translator);
	}

	/**
	 * Get translator for a format
	 */
	get(format: ApiFormat): Translator | undefined {
		return this.translators.get(format);
	}

	/**
	 * Detect format from request payload
	 */
	detectFormat(payload: Uint8Array): ApiFormat {
		try {
			const text = new TextDecoder().decode(payload);
			const data = JSON.parse(text) as Record<string, unknown>;

			// Anthropic uses "system" at top level and requires "max_tokens"
			if (data.system !== undefined || data.max_tokens !== undefined) {
				// Check if messages have Anthropic-style content blocks
				if (Array.isArray(data.messages)) {
					const firstMsg = data.messages[0] as Record<string, unknown> | undefined;
					if (firstMsg && Array.isArray(firstMsg.content)) {
						const contentBlock = (firstMsg.content as Array<Record<string, unknown>>)[0];
						if (contentBlock?.type === "text" || contentBlock?.type === "image") {
							return "anthropic";
						}
					}
				}
				// If it has max_tokens but no explicit type indicators, assume Anthropic
				if (data.max_tokens !== undefined && data.max_completion_tokens === undefined) {
					return "anthropic";
				}
			}

			// Default to OpenAI format (most common)
			return "openai";
		} catch {
			return "openai";
		}
	}

	/**
	 * Translate request from one format to another
	 */
	translate(
		payload: Uint8Array,
		sourceFormat: ApiFormat,
		targetFormat: ApiFormat,
	): TranslationResult {
		if (sourceFormat === targetFormat) {
			return { payload, format: targetFormat };
		}

		const source = this.get(sourceFormat);
		const target = this.get(targetFormat);

		if (!source || !target) {
			throw new Error(
				`Translator not found for ${source ? targetFormat : sourceFormat}`,
			);
		}

		// Parse to unified format, then build in target format
		const unified = source.parseRequest(payload);
		const translated = target.buildRequest(unified);

		return { payload: translated, format: targetFormat };
	}

	/**
	 * Translate response from one format to another
	 */
	translateResponse(
		payload: Uint8Array,
		sourceFormat: ApiFormat,
		targetFormat: ApiFormat,
	): TranslationResult {
		if (sourceFormat === targetFormat) {
			return { payload, format: targetFormat };
		}

		const source = this.get(sourceFormat);
		const target = this.get(targetFormat);

		if (!source || !target) {
			throw new Error(
				`Translator not found for ${source ? targetFormat : sourceFormat}`,
			);
		}

		// Parse to unified format, then build in target format
		const unified = source.parseResponse(payload);
		const translated = target.buildResponse(unified);

		return { payload: translated, format: targetFormat };
	}

	/**
	 * Parse request to unified format
	 */
	parseRequest(payload: Uint8Array, format?: ApiFormat): UnifiedRequest {
		const detectedFormat = format ?? this.detectFormat(payload);
		const translator = this.get(detectedFormat);

		if (!translator) {
			throw new Error(`Translator not found for ${detectedFormat}`);
		}

		return translator.parseRequest(payload);
	}

	/**
	 * Build request in specific format
	 */
	buildRequest(request: UnifiedRequest, format: ApiFormat): Uint8Array {
		const translator = this.get(format);

		if (!translator) {
			throw new Error(`Translator not found for ${format}`);
		}

		return translator.buildRequest(request);
	}

	/**
	 * Get format for a provider
	 */
	getProviderFormat(provider: string): ApiFormat {
		switch (provider) {
			case "claude":
			case "anthropic":
				return "anthropic";
			case "gemini":
				return "gemini";
			case "openai":
			case "copilot":
			case "qwen":
			case "iflow":
			default:
				return "openai";
		}
	}
}

// Default singleton instance
export const translatorRegistry = new TranslatorRegistry();
