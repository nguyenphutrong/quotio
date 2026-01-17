import type { StoredAuthFile } from "../store/types.js";
import type {
	ProviderExecutor,
	ExecutorRequest,
	ExecutorResponse,
	ExecutorOptions,
	StreamChunk,
} from "./types.js";
import { StatusError } from "./types.js";

const QWEN_API_BASE = "https://dashscope.aliyuncs.com/compatible-mode/v1";

interface QwenExecutorConfig {
	defaultMaxTokens?: number;
}

export class QwenExecutor implements ProviderExecutor {
	private config: QwenExecutorConfig;

	constructor(config: QwenExecutorConfig = {}) {
		this.config = {
			defaultMaxTokens: config.defaultMaxTokens ?? 8192,
		};
	}

	identifier(): string {
		return "qwen";
	}

	async execute(
		auth: StoredAuthFile,
		req: ExecutorRequest,
		opts: ExecutorOptions,
		signal?: AbortSignal,
	): Promise<ExecutorResponse> {
		const apiKey = this.getCredentials(auth);
		const url = `${QWEN_API_BASE}/chat/completions`;

		const body = this.prepareRequestBody(req, opts);

		const response = await fetch(url, {
			method: "POST",
			headers: this.buildHeaders(apiKey),
			body: JSON.stringify(body),
			signal,
		});

		if (!response.ok) {
			const errorText = await response.text();
			throw new StatusError(
				response.status,
				errorText,
				this.extractRetryAfterHeader(response),
			);
		}

		const data = await response.arrayBuffer();
		return { payload: new Uint8Array(data) };
	}

	async *executeStream(
		auth: StoredAuthFile,
		req: ExecutorRequest,
		opts: ExecutorOptions,
		signal?: AbortSignal,
	): AsyncGenerator<StreamChunk> {
		const apiKey = this.getCredentials(auth);
		const url = `${QWEN_API_BASE}/chat/completions`;

		const body = this.prepareRequestBody(req, opts);
		body.stream = true;

		const response = await fetch(url, {
			method: "POST",
			headers: this.buildHeaders(apiKey),
			body: JSON.stringify(body),
			signal,
		});

		if (!response.ok) {
			const errorText = await response.text();
			throw new StatusError(
				response.status,
				errorText,
				this.extractRetryAfterHeader(response),
			);
		}

		if (!response.body) {
			throw new StatusError(500, "No response body for streaming");
		}

		const reader = response.body.getReader();
		const decoder = new TextDecoder();

		try {
			while (true) {
				const { done, value } = await reader.read();
				if (done) break;

				const chunk = decoder.decode(value, { stream: true });
				yield { payload: new TextEncoder().encode(chunk) };
			}
		} catch (err) {
			yield { error: err instanceof Error ? err : new Error(String(err)) };
		} finally {
			reader.releaseLock();
		}
	}

	async refresh(auth: StoredAuthFile): Promise<StoredAuthFile> {
		// Qwen uses API key auth - no refresh needed
		// Just validate the key is present
		const apiKey =
			(auth.tokenData?.["api_key"] as string | undefined) ??
			(auth.tokenData?.["apiKey"] as string | undefined);

		if (!apiKey) {
			return {
				...auth,
				status: "error",
				statusMessage: "No API key configured",
				updatedAt: new Date().toISOString(),
			};
		}

		return {
			...auth,
			status: "ready",
			statusMessage: undefined,
			updatedAt: new Date().toISOString(),
		};
	}

	async countTokens(
		_auth: StoredAuthFile,
		_req: ExecutorRequest,
		_opts: ExecutorOptions,
		_signal?: AbortSignal,
	): Promise<ExecutorResponse> {
		throw new StatusError(501, "Token counting not supported for Qwen");
	}

	async prepareRequest(
		auth: StoredAuthFile,
		request: Request,
	): Promise<Request> {
		const apiKey = this.getCredentials(auth);
		const headers = new Headers(request.headers);

		headers.set("Authorization", `Bearer ${apiKey}`);
		headers.set("Content-Type", "application/json");

		return new Request(request.url, {
			method: request.method,
			headers,
			body: request.body,
		});
	}

	private getCredentials(auth: StoredAuthFile): string {
		const apiKey =
			(auth.tokenData?.["api_key"] as string | undefined) ??
			(auth.tokenData?.["apiKey"] as string | undefined);

		if (!apiKey) {
			throw new StatusError(401, "No API key configured for Qwen");
		}

		return apiKey;
	}

	private buildHeaders(apiKey: string): Record<string, string> {
		return {
			"Content-Type": "application/json",
			Authorization: `Bearer ${apiKey}`,
		};
	}

	private prepareRequestBody(
		req: ExecutorRequest,
		opts: ExecutorOptions,
	): Record<string, unknown> {
		const body = this.parsePayload(req.payload);

		// Use the model from request
		body.model = req.model;

		// Set default max_tokens if not provided
		if (!body.max_tokens && this.config.defaultMaxTokens) {
			body.max_tokens = this.config.defaultMaxTokens;
		}

		if (opts.stream) {
			body.stream = true;
		}

		return body;
	}

	private parsePayload(payload: Uint8Array): Record<string, unknown> {
		try {
			const text = new TextDecoder().decode(payload);
			return JSON.parse(text) as Record<string, unknown>;
		} catch {
			return {};
		}
	}

	private extractRetryAfterHeader(
		response: Response,
	): Record<string, string> | undefined {
		const retryAfter = response.headers.get("retry-after");
		if (retryAfter) {
			return { "retry-after": retryAfter };
		}
		return undefined;
	}
}
