import type { StoredAuthFile } from "../store/types.js";
import type {
	ProviderExecutor,
	ExecutorRequest,
	ExecutorResponse,
	ExecutorOptions,
	StreamChunk,
} from "./types.js";
import { StatusError } from "./types.js";

const IFLOW_API_BASE = "https://api.iflow.ai/v1";

interface IFlowExecutorConfig {
	defaultMaxTokens?: number;
}

export class IFlowExecutor implements ProviderExecutor {
	private config: IFlowExecutorConfig;

	constructor(config: IFlowExecutorConfig = {}) {
		this.config = {
			defaultMaxTokens: config.defaultMaxTokens ?? 4096,
		};
	}

	identifier(): string {
		return "iflow";
	}

	async execute(
		auth: StoredAuthFile,
		req: ExecutorRequest,
		opts: ExecutorOptions,
		signal?: AbortSignal,
	): Promise<ExecutorResponse> {
		const token = this.getCredentials(auth);
		const url = `${IFLOW_API_BASE}/chat/completions`;

		const body = this.prepareRequestBody(req, opts);

		const response = await fetch(url, {
			method: "POST",
			headers: this.buildHeaders(token),
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
		const token = this.getCredentials(auth);
		const url = `${IFLOW_API_BASE}/chat/completions`;

		const body = this.prepareRequestBody(req, opts);
		body.stream = true;

		const response = await fetch(url, {
			method: "POST",
			headers: this.buildHeaders(token),
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
		// iFlow uses OAuth bearer token - check if we have a valid token
		const accessToken = auth.accessToken;
		if (!accessToken) {
			return {
				...auth,
				status: "error",
				statusMessage: "No access token available",
				updatedAt: new Date().toISOString(),
			};
		}

		// Check expiry
		if (auth.expiresAt) {
			const expiresAt = new Date(auth.expiresAt);
			if (expiresAt.getTime() < Date.now() + 60000) {
				// Need refresh
				if (!auth.refreshToken) {
					return {
						...auth,
						status: "error",
						statusMessage: "Token expired and no refresh token",
						updatedAt: new Date().toISOString(),
					};
				}

				// TODO: Implement token refresh when iFlow OAuth refresh endpoint is known
				return {
					...auth,
					status: "error",
					statusMessage: "Token expired - refresh not implemented",
					updatedAt: new Date().toISOString(),
				};
			}
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
		throw new StatusError(501, "Token counting not supported for iFlow");
	}

	async prepareRequest(
		auth: StoredAuthFile,
		request: Request,
	): Promise<Request> {
		const token = this.getCredentials(auth);
		const headers = new Headers(request.headers);

		headers.set("Authorization", `Bearer ${token}`);
		headers.set("Content-Type", "application/json");

		return new Request(request.url, {
			method: request.method,
			headers,
			body: request.body,
		});
	}

	private getCredentials(auth: StoredAuthFile): string {
		// Try access token first (OAuth), then tokenData
		const token =
			auth.accessToken ??
			(auth.tokenData?.["access_token"] as string | undefined) ??
			(auth.tokenData?.["token"] as string | undefined);

		if (!token) {
			throw new StatusError(401, "No access token available for iFlow");
		}

		return token;
	}

	private buildHeaders(token: string): Record<string, string> {
		return {
			"Content-Type": "application/json",
			Authorization: `Bearer ${token}`,
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
