import type { StoredAuthFile } from "../store/types.js";
import type {
	ProviderExecutor,
	ExecutorRequest,
	ExecutorResponse,
	ExecutorOptions,
	StreamChunk,
} from "./types.js";
import { StatusError } from "./types.js";

const OPENAI_API_BASE = "https://api.openai.com";

interface OpenAIExecutorConfig {
	defaultMaxTokens?: number;
}

export class OpenAIExecutor implements ProviderExecutor {
	private config: OpenAIExecutorConfig;

	constructor(config: OpenAIExecutorConfig = {}) {
		this.config = {
			defaultMaxTokens: config.defaultMaxTokens ?? 4096,
		};
	}

	identifier(): string {
		return "openai";
	}

	async execute(
		auth: StoredAuthFile,
		req: ExecutorRequest,
		opts: ExecutorOptions,
		signal?: AbortSignal,
	): Promise<ExecutorResponse> {
		const { apiKey, baseUrl } = this.getCredentials(auth);
		const url = `${baseUrl}/v1/chat/completions`;

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
		const { apiKey, baseUrl } = this.getCredentials(auth);
		const url = `${baseUrl}/v1/chat/completions`;

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
		return auth;
	}

	async countTokens(
		_auth: StoredAuthFile,
		_req: ExecutorRequest,
		_opts: ExecutorOptions,
		_signal?: AbortSignal,
	): Promise<ExecutorResponse> {
		throw new StatusError(501, "Token counting not supported for OpenAI");
	}

	async prepareRequest(
		auth: StoredAuthFile,
		request: Request,
	): Promise<Request> {
		const { apiKey } = this.getCredentials(auth);
		const headers = new Headers(request.headers);

		headers.set("Authorization", `Bearer ${apiKey}`);
		headers.set("Content-Type", "application/json");

		return new Request(request.url, {
			method: request.method,
			headers,
			body: request.body,
		});
	}

	private getCredentials(auth: StoredAuthFile): {
		apiKey: string;
		baseUrl: string;
	} {
		const apiKey =
			(auth.tokenData?.["api_key"] as string) ?? auth.accessToken ?? "";
		const baseUrl =
			(auth.tokenData?.["base_url"] as string) ?? OPENAI_API_BASE;

		if (!apiKey) {
			throw new StatusError(401, "No API key or access token available");
		}

		return { apiKey, baseUrl };
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

		body.model = this.parseModelName(req.model);

		if (!body.max_tokens && !body.max_completion_tokens && this.config.defaultMaxTokens) {
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

	private parseModelName(model: string): string {
		const match = model.match(/^(.+?)(?:\(.*\))?$/);
		return match?.[1] ?? model;
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
