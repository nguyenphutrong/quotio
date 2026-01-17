import type { StoredAuthFile } from "../store/types.js";
import type {
	ProviderExecutor,
	ExecutorRequest,
	ExecutorResponse,
	ExecutorOptions,
	StreamChunk,
} from "./types.js";
import { StatusError } from "./types.js";

const COPILOT_API_BASE = "https://api.githubcopilot.com";
const COPILOT_TOKEN_URL = "https://api.github.com/copilot_internal/v2/token";

interface CopilotExecutorConfig {
	defaultMaxTokens?: number;
}

export class CopilotExecutor implements ProviderExecutor {
	private config: CopilotExecutorConfig;

	constructor(config: CopilotExecutorConfig = {}) {
		this.config = {
			defaultMaxTokens: config.defaultMaxTokens ?? 4096,
		};
	}

	identifier(): string {
		return "copilot";
	}

	async execute(
		auth: StoredAuthFile,
		req: ExecutorRequest,
		opts: ExecutorOptions,
		signal?: AbortSignal,
	): Promise<ExecutorResponse> {
		const { token, baseUrl } = await this.getCredentials(auth);
		const url = `${baseUrl}/chat/completions`;

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
		const { token, baseUrl } = await this.getCredentials(auth);
		const url = `${baseUrl}/chat/completions`;

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
		const oauthToken = auth.accessToken;
		if (!oauthToken) {
			return {
				...auth,
				status: "error",
				statusMessage: "No OAuth token available",
				updatedAt: new Date().toISOString(),
			};
		}

		try {
			const response = await fetch(COPILOT_TOKEN_URL, {
				method: "GET",
				headers: {
					Authorization: `token ${oauthToken}`,
					Accept: "application/json",
				},
			});

			if (!response.ok) {
				return {
					...auth,
					status: "error",
					statusMessage: "Token refresh failed",
					updatedAt: new Date().toISOString(),
				};
			}

			const data = (await response.json()) as {
				token: string;
				expires_at: number;
			};

			const now = new Date();
			const expiresAt = new Date(data.expires_at * 1000);

			return {
				...auth,
				tokenData: {
					...auth.tokenData,
					copilot_token: data.token,
					copilot_expires_at: expiresAt.toISOString(),
				},
				status: "ready",
				statusMessage: undefined,
				updatedAt: now.toISOString(),
			};
		} catch {
			return {
				...auth,
				status: "error",
				statusMessage: "Token refresh failed",
				updatedAt: new Date().toISOString(),
			};
		}
	}

	async countTokens(
		_auth: StoredAuthFile,
		_req: ExecutorRequest,
		_opts: ExecutorOptions,
		_signal?: AbortSignal,
	): Promise<ExecutorResponse> {
		throw new StatusError(501, "Token counting not supported for Copilot");
	}

	async prepareRequest(
		auth: StoredAuthFile,
		request: Request,
	): Promise<Request> {
		const { token } = await this.getCredentials(auth);
		const headers = new Headers(request.headers);

		headers.set("Authorization", `Bearer ${token}`);
		headers.set("Content-Type", "application/json");
		headers.set("Copilot-Integration-Id", "vscode-chat");

		return new Request(request.url, {
			method: request.method,
			headers,
			body: request.body,
		});
	}

	private async getCredentials(auth: StoredAuthFile): Promise<{
		token: string;
		baseUrl: string;
	}> {
		let token = auth.tokenData?.["copilot_token"] as string | undefined;
		const expiresAtStr = auth.tokenData?.["copilot_expires_at"] as string | undefined;
		const baseUrl = (auth.tokenData?.["base_url"] as string) ?? COPILOT_API_BASE;

		const isExpired = expiresAtStr
			? new Date(expiresAtStr).getTime() < Date.now() + 60000
			: true;

		if (!token || isExpired) {
			const refreshed = await this.refresh(auth);
			token = refreshed.tokenData?.["copilot_token"] as string;
		}

		if (!token) {
			throw new StatusError(401, "No Copilot token available");
		}

		return { token, baseUrl };
	}

	private buildHeaders(token: string): Record<string, string> {
		return {
			"Content-Type": "application/json",
			Authorization: `Bearer ${token}`,
			"Copilot-Integration-Id": "vscode-chat",
			"Editor-Version": "vscode/1.85.0",
			"Editor-Plugin-Version": "copilot-chat/0.12.0",
		};
	}

	private prepareRequestBody(
		req: ExecutorRequest,
		opts: ExecutorOptions,
	): Record<string, unknown> {
		const body = this.parsePayload(req.payload);

		body.model = this.parseModelName(req.model);

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
