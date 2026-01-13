import { describe, expect, test } from "bun:test";
import {
	APIFormat,
	convertRequest,
	detectFormat,
	getApiFormat,
	getAssistantRole,
	getDefaultMaxTokensParam,
	shouldTriggerFallback,
} from "../../src/services/format-converter.ts";
import { AIProvider } from "../../src/models/provider.ts";

describe("FallbackFormatConverter", () => {
	describe("APIFormat enum", () => {
		test("has correct format values", () => {
			expect(String(APIFormat.OPENAI)).toBe("openai");
			expect(String(APIFormat.ANTHROPIC)).toBe("anthropic");
			expect(String(APIFormat.GOOGLE)).toBe("google");
		});
	});

	describe("getApiFormat", () => {
		test("maps Claude to Anthropic format", () => {
			expect(getApiFormat(AIProvider.CLAUDE)).toBe(APIFormat.ANTHROPIC);
		});

		test("maps Kiro to Anthropic format", () => {
			expect(getApiFormat(AIProvider.KIRO)).toBe(APIFormat.ANTHROPIC);
		});

		test("maps Gemini/Vertex/Antigravity to Google format", () => {
			expect(getApiFormat(AIProvider.GEMINI)).toBe(APIFormat.GOOGLE);
			expect(getApiFormat(AIProvider.VERTEX)).toBe(APIFormat.GOOGLE);
			expect(getApiFormat(AIProvider.ANTIGRAVITY)).toBe(APIFormat.GOOGLE);
		});

		test("maps OpenAI-compatible providers to OpenAI format", () => {
			expect(getApiFormat(AIProvider.CODEX)).toBe(APIFormat.OPENAI);
			expect(getApiFormat(AIProvider.COPILOT)).toBe(APIFormat.OPENAI);
			expect(getApiFormat(AIProvider.CURSOR)).toBe(APIFormat.OPENAI);
			expect(getApiFormat(AIProvider.TRAE)).toBe(APIFormat.OPENAI);
			expect(getApiFormat(AIProvider.QWEN)).toBe(APIFormat.OPENAI);
			expect(getApiFormat(AIProvider.IFLOW)).toBe(APIFormat.OPENAI);
			expect(getApiFormat(AIProvider.GLM)).toBe(APIFormat.OPENAI);
		});
	});

	describe("getDefaultMaxTokensParam", () => {
		test("returns max_tokens for OpenAI", () => {
			expect(getDefaultMaxTokensParam(APIFormat.OPENAI)).toBe("max_tokens");
		});

		test("returns max_tokens for Anthropic", () => {
			expect(getDefaultMaxTokensParam(APIFormat.ANTHROPIC)).toBe("max_tokens");
		});

		test("returns maxOutputTokens for Google", () => {
			expect(getDefaultMaxTokensParam(APIFormat.GOOGLE)).toBe("maxOutputTokens");
		});
	});

	describe("getAssistantRole", () => {
		test("returns model for Google format", () => {
			expect(getAssistantRole(APIFormat.GOOGLE)).toBe("model");
		});

		test("returns assistant for other formats", () => {
			expect(getAssistantRole(APIFormat.OPENAI)).toBe("assistant");
			expect(getAssistantRole(APIFormat.ANTHROPIC)).toBe("assistant");
		});
	});

	describe("detectFormat", () => {
		test("detects OpenAI format from messages array with role/content", () => {
			const body = {
				model: "gpt-4",
				messages: [{ role: "user", content: "Hello" }],
			};
			expect(detectFormat(body)).toBe(APIFormat.OPENAI);
		});

		test("detects Anthropic format from messages + system field", () => {
			const body = {
				model: "claude-3",
				messages: [{ role: "user", content: "Hello" }],
				system: "You are a helpful assistant",
			};
			expect(detectFormat(body)).toBe(APIFormat.ANTHROPIC);
		});

		test("detects Anthropic format from content blocks with type field", () => {
			const body = {
				model: "claude-3",
				messages: [
					{
						role: "user",
						content: [{ type: "text", text: "Hello" }],
					},
				],
			};
			expect(detectFormat(body)).toBe(APIFormat.ANTHROPIC);
		});

		test("detects Google format from contents array with parts", () => {
			const body = {
				contents: [{ role: "user", parts: [{ text: "Hello" }] }],
			};
			expect(detectFormat(body)).toBe(APIFormat.GOOGLE);
		});

		test("detects Google format from system_instruction field", () => {
			const body = {
				contents: [{ role: "user", parts: [{ text: "Hello" }] }],
				system_instruction: { parts: [{ text: "Be helpful" }] },
			};
			expect(detectFormat(body)).toBe(APIFormat.GOOGLE);
		});
	});

	describe("convertRequest", () => {
		describe("OpenAI to Anthropic (Codex -> Claude)", () => {
			test("converts simple message", () => {
				const openaiRequest = {
					model: "gpt-4",
					messages: [{ role: "user", content: "Hello" }],
					max_tokens: 1000,
				};

				const result = convertRequest(openaiRequest, AIProvider.CODEX, AIProvider.CLAUDE);

				expect(result.messages).toBeDefined();
				expect(Array.isArray(result.messages)).toBe(true);
				const messages = result.messages as Array<{ role: string; content: unknown }>;
				expect(messages[0]?.role).toBe("user");
			});

			test("extracts system message to top-level system field", () => {
				const openaiRequest = {
					model: "gpt-4",
					messages: [
						{ role: "system", content: "You are helpful" },
						{ role: "user", content: "Hello" },
					],
				};

				const result = convertRequest(openaiRequest, AIProvider.CODEX, AIProvider.CLAUDE);

				expect(result.system).toBe("You are helpful");
				const messages = result.messages as Array<{ role: string }>;
				expect(messages.every((m) => m.role !== "system")).toBe(true);
			});
		});

		describe("Anthropic to OpenAI (Claude -> Codex)", () => {
			test("converts content blocks to string", () => {
				const anthropicRequest = {
					model: "claude-3",
					messages: [
						{
							role: "user",
							content: [{ type: "text", text: "Hello world" }],
						},
					],
					system: "Be helpful",
				};

				const result = convertRequest(anthropicRequest, AIProvider.CLAUDE, AIProvider.CODEX);

				expect(result.messages).toBeDefined();
				const messages = result.messages as Array<{ role: string; content: string }>;
				const userMsg = messages.find((m) => m.role === "user");
				expect(userMsg?.content).toBe("Hello world");
			});

			test("converts system field to system message", () => {
				const anthropicRequest = {
					model: "claude-3",
					messages: [{ role: "user", content: "Hello" }],
					system: "You are a helpful assistant",
				};

				const result = convertRequest(anthropicRequest, AIProvider.CLAUDE, AIProvider.CODEX);

				const messages = result.messages as Array<{ role: string; content: string }>;
				const systemMsg = messages.find((m) => m.role === "system");
				expect(systemMsg?.content).toBe("You are a helpful assistant");
			});
		});

		describe("OpenAI to Google (Codex -> Gemini)", () => {
			// NOTE: Swift FallbackFormatConverter does NOT rename messages -> contents.
			// It only converts content format and role names within the existing structure.
			test("converts assistant role to model role in messages", () => {
				const openaiRequest = {
					model: "gpt-4",
					messages: [
						{ role: "user", content: "Hello" },
						{ role: "assistant", content: "Hi there!" },
					],
				};

				const result = convertRequest(openaiRequest, AIProvider.CODEX, AIProvider.GEMINI);

				// Messages stay as messages, but roles are converted
				expect(result.messages).toBeDefined();
				const messages = result.messages as Array<{ role: string }>;
				const modelMsg = messages.find((m) => m.role === "model");
				expect(modelMsg).toBeDefined();
			});

			test("removes system field for Google format", () => {
				const openaiRequest = {
					model: "gpt-4",
					messages: [
						{ role: "system", content: "Be helpful" },
						{ role: "user", content: "Hello" },
					],
				};

				const result = convertRequest(openaiRequest, AIProvider.CODEX, AIProvider.GEMINI);

				// Swift removes 'system' field for Google format in cleanupIncompatibleFields
				expect(result.system).toBeUndefined();
			});
		});

		describe("Google to OpenAI (Gemini -> Codex)", () => {
			// NOTE: Swift FallbackFormatConverter does NOT rename contents -> messages.
			// If request has 'contents', it stays as 'contents' (cleanup removes it for OpenAI target).
			test("cleans up contents field for OpenAI target", () => {
				const googleRequest = {
					contents: [{ role: "user", parts: [{ text: "Hello" }] }],
				};

				const result = convertRequest(googleRequest, AIProvider.GEMINI, AIProvider.CODEX);

				// Swift cleanupIncompatibleFields removes 'contents' for OpenAI format
				expect(result.contents).toBeUndefined();
			});

			test("removes system_instruction for OpenAI target", () => {
				const googleRequest = {
					contents: [{ role: "user", parts: [{ text: "Hello" }] }],
					system_instruction: { parts: [{ text: "Be helpful" }] },
				};

				const result = convertRequest(googleRequest, AIProvider.GEMINI, AIProvider.CODEX);

				// Swift cleanupIncompatibleFields removes 'system_instruction' for OpenAI format
				expect(result.system_instruction).toBeUndefined();
			});
		});

		describe("same format passthrough (Codex -> Copilot)", () => {
			test("preserves structure when source and target use same format", () => {
				const request = {
					model: "gpt-4",
					messages: [{ role: "user", content: "Hello" }],
				};

				const result = convertRequest(request, AIProvider.CODEX, AIProvider.COPILOT);

				expect(result.messages).toBeDefined();
				const messages = result.messages as Array<{ role: string; content: string }>;
				expect(messages[0]?.content).toBe("Hello");
			});
		});
	});

	describe("shouldTriggerFallback", () => {
		describe("HTTP status codes", () => {
			test("triggers on 429 rate limit", () => {
				const response = "HTTP/1.1 429 Too Many Requests\r\n\r\n{}";
				expect(shouldTriggerFallback(response)).toBe(true);
			});

			test("triggers on 503 service unavailable", () => {
				const response = "HTTP/1.1 503 Service Unavailable\r\n\r\n{}";
				expect(shouldTriggerFallback(response)).toBe(true);
			});

			test("triggers on 500 internal server error", () => {
				const response = "HTTP/1.1 500 Internal Server Error\r\n\r\n{}";
				expect(shouldTriggerFallback(response)).toBe(true);
			});

			test("triggers on 400 bad request", () => {
				const response = "HTTP/1.1 400 Bad Request\r\n\r\n{}";
				expect(shouldTriggerFallback(response)).toBe(true);
			});

			test("triggers on 401 unauthorized", () => {
				const response = "HTTP/1.1 401 Unauthorized\r\n\r\n{}";
				expect(shouldTriggerFallback(response)).toBe(true);
			});

			test("triggers on 403 forbidden", () => {
				const response = "HTTP/1.1 403 Forbidden\r\n\r\n{}";
				expect(shouldTriggerFallback(response)).toBe(true);
			});

			test("triggers on 422 unprocessable entity", () => {
				const response = "HTTP/1.1 422 Unprocessable Entity\r\n\r\n{}";
				expect(shouldTriggerFallback(response)).toBe(true);
			});

			test("does not trigger on 200 OK", () => {
				const response = "HTTP/1.1 200 OK\r\n\r\n{}";
				expect(shouldTriggerFallback(response)).toBe(false);
			});

			test("does not trigger on 201 Created", () => {
				const response = "HTTP/1.1 201 Created\r\n\r\n{}";
				expect(shouldTriggerFallback(response)).toBe(false);
			});
		});

		describe("error patterns in body", () => {
			// NOTE: Swift returns false immediately for 200-299 status codes.
			// Error patterns are ONLY checked when status code extraction fails or is non-2xx.
			test("triggers on quota exceeded with non-2xx status", () => {
				const response = 'HTTP/1.1 500 Internal Server Error\r\n\r\n{"error": "Quota exceeded for today"}';
				expect(shouldTriggerFallback(response)).toBe(true);
			});

			test("triggers on rate limit message with non-2xx status", () => {
				const response =
					'HTTP/1.1 429 Too Many Requests\r\n\r\n{"error": "Rate limit reached, please retry"}';
				expect(shouldTriggerFallback(response)).toBe(true);
			});

			test("triggers on insufficient_quota pattern", () => {
				// Pattern check only when status is not explicitly 2xx
				const response = 'insufficient_quota error occurred';
				expect(shouldTriggerFallback(response)).toBe(true);
			});

			test("triggers on resource_exhausted pattern", () => {
				const response = 'resource_exhausted in response';
				expect(shouldTriggerFallback(response)).toBe(true);
			});

			test("triggers on too many requests pattern", () => {
				const response = '{"message": "Too many requests"}';
				expect(shouldTriggerFallback(response)).toBe(true);
			});

			test("triggers on overloaded pattern", () => {
				const response = '{"error": "Server is overloaded"}';
				expect(shouldTriggerFallback(response)).toBe(true);
			});

			test("triggers on authentication pattern", () => {
				const response = '{"error": "Authentication failed"}';
				expect(shouldTriggerFallback(response)).toBe(true);
			});

			test("triggers on model not found pattern", () => {
				const response = '{"error": "Model not found: claude-5"}';
				expect(shouldTriggerFallback(response)).toBe(true);
			});

			test("does not trigger on 200 OK even with error-like words in body", () => {
				// Swift explicitly returns false for 2xx status codes BEFORE checking patterns
				const response =
					'HTTP/1.1 200 OK\r\n\r\n{"id": "123", "choices": [{"message": {"content": "Hello!"}}]}';
				expect(shouldTriggerFallback(response)).toBe(false);
			});

			test("does not trigger on 200 OK with quota exceeded in body", () => {
				// Swift behavior: 200 status returns false immediately, patterns not checked
				const response = 'HTTP/1.1 200 OK\r\n\r\n{"error": "Quota exceeded for today"}';
				expect(shouldTriggerFallback(response)).toBe(false);
			});
		});
	});
});
