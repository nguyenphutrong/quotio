import type {
	APIKeysResponse,
	AuthFile,
	AuthFilesResponse,
	LogsResponse,
	OAuthStatusResponse,
	OAuthURLResponse,
} from "../models/auth.ts";
import { parseAuthFile } from "../models/auth.ts";
import type { AppConfig, ProxyStatus } from "../models/config.ts";
import { parseAppConfig } from "../models/config.ts";
import type { AIProvider } from "../models/provider.ts";
import type { UsageStats } from "../models/quota.ts";
import { parseUsageStats } from "../models/quota.ts";

export class APIError extends Error {
	constructor(
		message: string,
		public readonly statusCode?: number,
	) {
		super(message);
		this.name = "APIError";
	}

	static invalidURL(): APIError {
		return new APIError("Invalid URL");
	}

	static invalidResponse(): APIError {
		return new APIError("Invalid response");
	}

	static httpError(statusCode: number): APIError {
		return new APIError(`HTTP error: ${statusCode}`, statusCode);
	}

	static connectionError(message: string): APIError {
		return new APIError(`Connection error: ${message}`);
	}
}

export interface TimeoutConfig {
	requestTimeoutMs: number;
	maxRetries: number;
}

export const DEFAULT_LOCAL_TIMEOUT: TimeoutConfig = {
	requestTimeoutMs: 15000,
	maxRetries: 1,
};

export const DEFAULT_REMOTE_TIMEOUT: TimeoutConfig = {
	requestTimeoutMs: 30000,
	maxRetries: 2,
};

export interface ManagementAPIClientOptions {
	baseURL: string;
	authKey: string;
	timeout?: TimeoutConfig;
	isRemote?: boolean;
}

export class ManagementAPIClient {
	private readonly baseURL: string;
	private readonly authKey: string;
	private readonly timeout: TimeoutConfig;
	readonly isRemote: boolean;

	constructor(options: ManagementAPIClientOptions) {
		this.baseURL = options.baseURL.replace(/\/$/, "");
		this.authKey = options.authKey;
		this.isRemote = options.isRemote ?? false;
		this.timeout =
			options.timeout ??
			(this.isRemote ? DEFAULT_REMOTE_TIMEOUT : DEFAULT_LOCAL_TIMEOUT);
	}

	private async makeRequest(
		endpoint: string,
		method = "GET",
		body?: unknown,
		retryCount = 0,
	): Promise<unknown> {
		const url = `${this.baseURL}${endpoint}`;
		const controller = new AbortController();
		const timeoutId = setTimeout(
			() => controller.abort(),
			this.timeout.requestTimeoutMs,
		);

		try {
			const response = await fetch(url, {
				method,
				headers: {
					Authorization: `Bearer ${this.authKey}`,
					"Content-Type": "application/json",
					Connection: "close",
				},
				body: body ? JSON.stringify(body) : undefined,
				signal: controller.signal,
			});

			clearTimeout(timeoutId);

			if (!response.ok) {
				throw APIError.httpError(response.status);
			}

			const text = await response.text();
			if (!text) return {};
			return JSON.parse(text);
		} catch (error) {
			clearTimeout(timeoutId);

			if (error instanceof APIError) throw error;

			const isRetryable =
				error instanceof Error &&
				(error.name === "AbortError" ||
					error.message.includes("ECONNREFUSED") ||
					error.message.includes("ETIMEDOUT"));

			if (isRetryable && retryCount < this.timeout.maxRetries) {
				await Bun.sleep(500);
				return this.makeRequest(endpoint, method, body, retryCount + 1);
			}

			throw APIError.connectionError(
				error instanceof Error ? error.message : String(error),
			);
		}
	}

	async fetchAuthFiles(): Promise<AuthFile[]> {
		const data = (await this.makeRequest("/auth-files")) as AuthFilesResponse;
		return (data.files ?? []).map((f) =>
			parseAuthFile(f as unknown as Record<string, unknown>),
		);
	}

	async deleteAuthFile(name: string): Promise<void> {
		await this.makeRequest(
			`/auth-files?name=${encodeURIComponent(name)}`,
			"DELETE",
		);
	}

	async deleteAllAuthFiles(): Promise<void> {
		await this.makeRequest("/auth-files?all=true", "DELETE");
	}

	async fetchUsageStats(): Promise<UsageStats> {
		const data = (await this.makeRequest("/usage")) as Record<string, unknown>;
		return parseUsageStats(data);
	}

	async getOAuthURL(
		provider: AIProvider,
		options?: { projectId?: string; isWebUI?: boolean },
	): Promise<OAuthURLResponse> {
		const { PROVIDER_METADATA } = await import("../models/provider.ts");
		const metadata = PROVIDER_METADATA[provider];

		if (!metadata.oauthEndpoint) {
			throw new APIError(`Provider ${provider} does not support OAuth`);
		}

		const params = new URLSearchParams();
		if (options?.projectId && provider === "gemini-cli") {
			params.set("project_id", options.projectId);
		}
		if (options?.isWebUI !== false) {
			params.set("is_webui", "true");
		}

		const queryString = params.toString();
		const endpoint = queryString
			? `${metadata.oauthEndpoint}?${queryString}`
			: metadata.oauthEndpoint;

		return (await this.makeRequest(endpoint)) as OAuthURLResponse;
	}

	async pollOAuthStatus(state: string): Promise<OAuthStatusResponse> {
		return (await this.makeRequest(
			`/get-auth-status?state=${encodeURIComponent(state)}`,
		)) as OAuthStatusResponse;
	}

	async fetchConfig(): Promise<AppConfig> {
		const data = (await this.makeRequest("/config")) as Record<string, unknown>;
		return parseAppConfig(data);
	}

	async setDebug(enabled: boolean): Promise<void> {
		await this.makeRequest("/debug", "PUT", { value: enabled });
	}

	async getDebug(): Promise<boolean> {
		const data = (await this.makeRequest("/debug")) as { debug: boolean };
		return data.debug;
	}

	async setRoutingStrategy(
		strategy: "round-robin" | "fill-first",
	): Promise<void> {
		try {
			await this.makeRequest("/routing/strategy", "PUT", { value: strategy });
		} catch (error) {
			if (error instanceof APIError && error.statusCode === 404) {
				await this.makeRequest("/routing", "PUT", { strategy });
			} else {
				throw error;
			}
		}
	}

	async getRoutingStrategy(): Promise<string> {
		try {
			const data = (await this.makeRequest("/routing/strategy")) as {
				strategy: string;
			};
			return data.strategy;
		} catch (error) {
			if (error instanceof APIError && error.statusCode === 404) {
				const data = (await this.makeRequest("/routing")) as {
					strategy: string;
				};
				return data.strategy;
			}
			throw error;
		}
	}

	async setQuotaExceededSwitchProject(enabled: boolean): Promise<void> {
		await this.makeRequest("/quota-exceeded/switch-project", "PATCH", {
			value: enabled,
		});
	}

	async setQuotaExceededSwitchPreviewModel(enabled: boolean): Promise<void> {
		await this.makeRequest("/quota-exceeded/switch-preview-model", "PATCH", {
			value: enabled,
		});
	}

	async setRequestRetry(count: number): Promise<void> {
		await this.makeRequest("/request-retry", "PUT", { value: count });
	}

	async getRequestRetry(): Promise<number> {
		const data = (await this.makeRequest("/request-retry")) as {
			request_retry: number;
		};
		return data.request_retry;
	}

	async setMaxRetryInterval(seconds: number): Promise<void> {
		await this.makeRequest("/max-retry-interval", "PUT", { value: seconds });
	}

	async getMaxRetryInterval(): Promise<number> {
		const data = (await this.makeRequest("/max-retry-interval")) as {
			max_retry_interval: number;
		};
		return data.max_retry_interval;
	}

	async fetchAPIKeys(): Promise<string[]> {
		const data = (await this.makeRequest("/api-keys")) as APIKeysResponse;
		return data["api-keys"] ?? [];
	}

	async addAPIKey(): Promise<string> {
		const data = (await this.makeRequest("/api-keys", "POST")) as {
			"api-key": string;
		};
		return data["api-key"];
	}

	async deleteAPIKey(key: string): Promise<void> {
		await this.makeRequest(
			`/api-keys?key=${encodeURIComponent(key)}`,
			"DELETE",
		);
	}

	async setAuthFileDisabled(name: string, disabled: boolean): Promise<void> {
		const endpoint = disabled ? "/auth-files/disable" : "/auth-files/enable";
		await this.makeRequest(
			`${endpoint}?name=${encodeURIComponent(name)}`,
			"PUT",
		);
	}

	async setProxyURL(url: string): Promise<void> {
		await this.makeRequest("/proxy-url", "PUT", { value: url });
	}

	async getProxyURL(): Promise<string> {
		const data = (await this.makeRequest("/proxy-url")) as {
			proxy_url: string;
		};
		return data.proxy_url;
	}

	async deleteProxyURL(): Promise<void> {
		await this.makeRequest("/proxy-url", "DELETE");
	}

	async setLoggingToFile(enabled: boolean): Promise<void> {
		await this.makeRequest("/logging-to-file", "PUT", { value: enabled });
	}

	async getLoggingToFile(): Promise<boolean> {
		const data = (await this.makeRequest("/logging-to-file")) as {
			logging_to_file: boolean;
		};
		return data.logging_to_file;
	}

	async healthCheck(): Promise<boolean> {
		try {
			await this.makeRequest("/health");
			return true;
		} catch {
			return false;
		}
	}

	async fetchLogs(after?: number): Promise<LogsResponse> {
		let endpoint = "/logs";
		if (after !== undefined) {
			endpoint += `?after=${after}`;
		}
		return (await this.makeRequest(endpoint)) as LogsResponse;
	}

	async clearLogs(): Promise<void> {
		await this.makeRequest("/logs", "DELETE");
	}
}

export function createLocalClient(
	port = 8317,
	authKey = "",
): ManagementAPIClient {
	return new ManagementAPIClient({
		baseURL: `http://localhost:${port}`,
		authKey,
		isRemote: false,
	});
}

export function createRemoteClient(
	baseURL: string,
	authKey: string,
	timeout?: TimeoutConfig,
): ManagementAPIClient {
	return new ManagementAPIClient({
		baseURL,
		authKey,
		isRemote: true,
		timeout: timeout ?? DEFAULT_REMOTE_TIMEOUT,
	});
}
