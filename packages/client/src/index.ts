/**
 * @quotio/client - TypeScript HTTP client for quotio-cli daemon.
 * Cross-platform IPC via HTTP (port 18318).
 */

import type {
	AgentConfigureResult,
	AgentDetectResult,
	AuthListResult,
	DaemonStatus,
	FallbackConfigResult,
	IPCMethods,
	JsonRpcErrorResponse,
	JsonRpcSuccessResponse,
	LogsFetchResult,
	MethodName,
	MethodParams,
	MethodResult,
	ProxyStartResult,
	ProxyStatusResult,
	QuotaFetchResult,
	QuotaListResult,
	StatsGetResult,
} from '@quotio/cli';

export class DaemonClientError extends Error {
	constructor(
		public readonly code: number,
		message: string,
		public readonly data?: unknown,
	) {
		super(message);
		this.name = 'DaemonClientError';
	}
}

export interface DaemonClientOptions {
	baseURL?: string;
	timeout?: number;
}

export class DaemonClient {
	private readonly baseURL: string;
	private readonly timeout: number;
	private requestId = 0;

	constructor(options: DaemonClientOptions = {}) {
		this.baseURL = options.baseURL ?? 'http://127.0.0.1:18318';
		this.timeout = options.timeout ?? 30000;
	}

	async call<M extends MethodName>(method: M, params?: MethodParams<M>): Promise<MethodResult<M>> {
		const id = ++this.requestId;
		const body = JSON.stringify({
			jsonrpc: '2.0',
			id,
			method,
			...(params !== undefined && { params }),
		});

		const controller = new AbortController();
		const timeoutId = setTimeout(() => controller.abort(), this.timeout);

		try {
			const response = await fetch(`${this.baseURL}/rpc`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body,
				signal: controller.signal,
			});

			if (!response.ok) {
				throw new DaemonClientError(
					response.status,
					`HTTP ${response.status}: ${response.statusText}`,
				);
			}

			const json = (await response.json()) as
				| JsonRpcSuccessResponse<MethodResult<M>>
				| JsonRpcErrorResponse;

			if ('error' in json) {
				throw new DaemonClientError(json.error.code, json.error.message, json.error.data);
			}

			return json.result;
		} finally {
			clearTimeout(timeoutId);
		}
	}

	async health(): Promise<{ status: string; version: string; timestamp: number }> {
		const response = await fetch(`${this.baseURL}/health`);
		if (!response.ok) {
			throw new DaemonClientError(response.status, `Health check failed: ${response.statusText}`);
		}
		return response.json() as Promise<{ status: string; version: string; timestamp: number }>;
	}

	async ping(): Promise<{ pong: true; timestamp: number }> {
		return this.call('daemon.ping', {});
	}

	async getStatus(): Promise<DaemonStatus> {
		return this.call('daemon.status', {});
	}

	async shutdown(graceful = true): Promise<{ success: true }> {
		return this.call('daemon.shutdown', { graceful });
	}

	async startProxy(port?: number): Promise<ProxyStartResult> {
		return this.call('proxy.start', { port });
	}

	async stopProxy(): Promise<{ success: true }> {
		return this.call('proxy.stop', {});
	}

	async getProxyStatus(): Promise<ProxyStatusResult> {
		return this.call('proxy.status', {});
	}

	async proxyHealth(): Promise<{ healthy: boolean }> {
		return this.call('proxy.health', {});
	}

	async listAuth(provider?: string): Promise<AuthListResult> {
		return this.call('auth.list', { provider });
	}

	async deleteAuth(name: string): Promise<{ success: boolean; error?: string }> {
		return this.call('auth.delete', { name });
	}

	async startOAuth(
		provider: string,
		projectId?: string,
	): Promise<{ success: boolean; url?: string; state?: string; error?: string }> {
		return this.call('oauth.start', { provider, projectId });
	}

	async pollOAuth(
		state: string,
	): Promise<{ status: 'pending' | 'success' | 'error'; error?: string }> {
		return this.call('oauth.poll', { state });
	}

	async fetchQuotas(provider?: string, forceRefresh?: boolean): Promise<QuotaFetchResult> {
		return this.call('quota.fetch', { provider, forceRefresh });
	}

	async listQuotas(): Promise<QuotaListResult> {
		return this.call('quota.list', {});
	}

	async detectAgents(forceRefresh?: boolean): Promise<AgentDetectResult> {
		return this.call('agent.detect', { forceRefresh });
	}

	async configureAgent(agent: string, mode: 'auto' | 'manual'): Promise<AgentConfigureResult> {
		return this.call('agent.configure', { agent, mode });
	}

	async getFallbackConfig(): Promise<FallbackConfigResult> {
		return this.call('fallback.getConfig', {});
	}

	async setFallbackEnabled(enabled: boolean): Promise<{ success: true }> {
		return this.call('fallback.setEnabled', { enabled });
	}

	async fetchLogs(after?: number): Promise<LogsFetchResult> {
		return this.call('logs.fetch', { after });
	}

	async clearLogs(): Promise<{ success: boolean; error?: string }> {
		return this.call('logs.clear', {});
	}

	async getStats(): Promise<StatsGetResult> {
		return this.call('stats.get', {});
	}

	async getConfig(key: string): Promise<{ value: unknown }> {
		return this.call('config.get', { key });
	}

	async setConfig(key: string, value: unknown): Promise<{ success: true }> {
		return this.call('config.set', { key, value });
	}
}

export function createDaemonClient(options?: DaemonClientOptions): DaemonClient {
	return new DaemonClient(options);
}

export type { IPCMethods, MethodName, MethodParams, MethodResult };
