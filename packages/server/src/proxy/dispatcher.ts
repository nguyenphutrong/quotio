import type { FallbackConfiguration } from '@quotio/core';
import {
	ClaudeExecutor,
	CopilotExecutor,
	CredentialPool,
	type ExecutorOptions,
	type ExecutorRequest,
	GeminiExecutor,
	IFlowExecutor,
	OpenAIExecutor,
	type ProviderExecutor,
	QwenExecutor,
	RoundRobinSelector,
	StatusError,
} from '../executor/index.js';
import type { TokenStore } from '../store/types.js';
import {
	type FallbackContext,
	createFallbackContext,
	getCurrentEntry,
	handleFallbackSuccess,
	hasFallback,
	hasMoreFallbacks,
	mapProviderToExecutor,
	nextFallbackContext,
	replaceModelInPayload,
	shouldTriggerFallback,
	updateRouteState,
} from './fallback.js';
import type { ProxyRequest } from './types.js';
import { inferProviderFromModel } from './types.js';

/**
 * Proxy response with execution info
 */
export interface ProxyResponse {
	/** Response payload */
	payload: Uint8Array;
	/** Model used */
	model: string;
	/** Execution time in ms */
	durationMs: number;
}

/**
 * Streaming chunk
 */
export interface ProxyStreamChunk {
	/** Chunk payload */
	payload: Uint8Array;
	/** Error if any */
	error?: Error;
	/** Is final chunk */
	done?: boolean;
}

export interface DispatcherConfig {
	defaultMaxTokens?: number;
	debug?: boolean;
	fallbackConfig?: FallbackConfiguration;
}

/**
 * ProxyDispatcher routes requests to provider executors
 */
export class ProxyDispatcher {
	private pool: CredentialPool;
	private executors: Map<string, ProviderExecutor> = new Map();
	private config: DispatcherConfig;
	private initialized = false;

	constructor(
		private store: TokenStore,
		config: DispatcherConfig = {},
	) {
		this.config = {
			defaultMaxTokens: config.defaultMaxTokens ?? 8192,
			debug: config.debug ?? false,
			fallbackConfig: config.fallbackConfig,
		};

		this.pool = new CredentialPool({
			store,
			selector: new RoundRobinSelector(),
		});

		this.registerDefaultExecutors();
	}

	private registerDefaultExecutors(): void {
		const claude = new ClaudeExecutor({
			defaultMaxTokens: this.config.defaultMaxTokens,
		});
		const gemini = new GeminiExecutor({
			defaultMaxTokens: this.config.defaultMaxTokens,
		});
		const openai = new OpenAIExecutor({
			defaultMaxTokens: this.config.defaultMaxTokens,
		});
		const copilot = new CopilotExecutor({
			defaultMaxTokens: this.config.defaultMaxTokens,
		});
		const qwen = new QwenExecutor({
			defaultMaxTokens: this.config.defaultMaxTokens,
		});
		const iflow = new IFlowExecutor({
			defaultMaxTokens: this.config.defaultMaxTokens,
		});

		this.executors.set(claude.identifier(), claude);
		this.executors.set(gemini.identifier(), gemini);
		this.executors.set(openai.identifier(), openai);
		this.executors.set(copilot.identifier(), copilot);
		this.executors.set(qwen.identifier(), qwen);
		this.executors.set(iflow.identifier(), iflow);

		this.pool.registerExecutor(claude);
		this.pool.registerExecutor(gemini);
		this.pool.registerExecutor(openai);
		this.pool.registerExecutor(copilot);
		this.pool.registerExecutor(qwen);
		this.pool.registerExecutor(iflow);
	}

	/**
	 * Initialize the dispatcher (load auth files)
	 */
	async initialize(): Promise<void> {
		if (this.initialized) return;
		await this.pool.load();
		this.initialized = true;

		if (this.config.debug) {
			console.log('[dispatcher] initialized with executors:', [...this.executors.keys()]);
		}
	}

	/**
	 * Dispatch a request to the appropriate provider
	 */
	async dispatch(request: ProxyRequest, signal?: AbortSignal): Promise<ProxyResponse> {
		await this.initialize();

		const startTime = Date.now();
		const providers = this.resolveProviders(request);

		if (providers.length === 0) {
			throw new DispatchError(400, `No provider available for model: ${request.model}`);
		}

		const executorReq: ExecutorRequest = {
			model: request.model,
			payload: request.payload,
			metadata: request.metadata,
		};

		const opts: ExecutorOptions = {
			stream: request.stream,
		};

		try {
			const result = await this.pool.execute(providers, executorReq, opts, signal);

			return {
				payload: result.payload,
				model: request.model,
				durationMs: Date.now() - startTime,
			};
		} catch (err) {
			if (this.config.debug) {
				console.error('[dispatcher] dispatch error:', err);
			}
			throw err;
		}
	}

	/**
	 * Dispatch a streaming request
	 */
	async *dispatchStream(
		request: ProxyRequest,
		signal?: AbortSignal,
	): AsyncGenerator<ProxyStreamChunk> {
		await this.initialize();

		const providers = this.resolveProviders(request);

		if (providers.length === 0) {
			yield { payload: new Uint8Array(), error: new Error('No provider available') };
			return;
		}

		const executorReq: ExecutorRequest = {
			model: request.model,
			payload: request.payload,
			metadata: request.metadata,
		};

		const opts: ExecutorOptions = {
			stream: true,
		};

		try {
			const stream = this.pool.executeStream(providers, executorReq, opts, signal);

			for await (const chunk of stream) {
				yield {
					payload: chunk.payload ?? new Uint8Array(),
					error: chunk.error,
				};
			}

			yield { payload: new Uint8Array(), done: true };
		} catch (err) {
			yield {
				payload: new Uint8Array(),
				error: err instanceof Error ? err : new Error(String(err)),
			};
		}
	}

	/**
	 * Get available models from all auths
	 */
	async getAvailableModels(): Promise<string[]> {
		await this.initialize();

		const authFiles = await this.store.listAuthFiles();
		const models = new Set<string>();

		for (const auth of authFiles) {
			if (auth.disabled || auth.status === 'error') continue;

			// Get models for this provider
			const providerModels = this.getModelsForProvider(auth.provider);
			for (const model of providerModels) {
				models.add(model);
			}
		}

		return [...models].sort();
	}

	/**
	 * Get available providers
	 */
	getAvailableProviders(): string[] {
		return [...this.executors.keys()];
	}

	setFallbackConfig(config: FallbackConfiguration | undefined): void {
		this.config.fallbackConfig = config;
	}

	getFallbackConfig(): FallbackConfiguration | undefined {
		return this.config.fallbackConfig;
	}

	async dispatchWithFallback(request: ProxyRequest, signal?: AbortSignal): Promise<ProxyResponse> {
		await this.initialize();

		const fallbackConfig = this.config.fallbackConfig;
		if (!fallbackConfig) {
			return this.dispatch(request, signal);
		}

		const fallbackCtx = createFallbackContext(fallbackConfig, request.model, request.payload);

		if (!hasFallback(fallbackCtx)) {
			return this.dispatch(request, signal);
		}

		return this.executeWithFallback(request, fallbackCtx, signal);
	}

	private async executeWithFallback(
		request: ProxyRequest,
		fallbackCtx: FallbackContext,
		signal?: AbortSignal,
	): Promise<ProxyResponse> {
		const startTime = Date.now();
		let currentCtx = fallbackCtx;

		while (true) {
			const entry = getCurrentEntry(currentCtx);
			if (!entry) {
				throw new DispatchError(500, 'No fallback entry available');
			}

			const provider = mapProviderToExecutor(entry.provider);
			if (!this.executors.has(provider)) {
				if (hasMoreFallbacks(currentCtx)) {
					currentCtx = nextFallbackContext(currentCtx);
					continue;
				}
				throw new DispatchError(400, `Provider not available: ${provider}`);
			}

			const modifiedPayload = replaceModelInPayload(currentCtx.originalPayload, entry.modelId);

			const modifiedRequest: ProxyRequest = {
				...request,
				model: entry.modelId,
				providers: [provider],
				payload: modifiedPayload,
			};

			if (this.config.debug) {
				console.log(
					`[dispatcher] Trying fallback entry ${currentCtx.currentIndex + 1}/${currentCtx.fallbackEntries.length}: ${entry.provider} → ${entry.modelId}`,
				);
			}

			try {
				const result = await this.dispatch(modifiedRequest, signal);

				handleFallbackSuccess(currentCtx);
				if (currentCtx.virtualModelName) {
					updateRouteState(
						currentCtx.virtualModelName,
						currentCtx.currentIndex,
						entry,
						currentCtx.fallbackEntries.length,
					);
				}

				return {
					...result,
					model: currentCtx.virtualModelName || entry.modelId,
					durationMs: Date.now() - startTime,
				};
			} catch (err) {
				const statusCode = err instanceof StatusError ? err.statusCode : 500;
				const responseBody = err instanceof Error ? err.message : '';

				if (shouldTriggerFallback(statusCode, responseBody) && hasMoreFallbacks(currentCtx)) {
					if (this.config.debug) {
						console.log(
							`[dispatcher] Fallback triggered (status: ${statusCode}), trying next entry`,
						);
					}

					if (currentCtx.virtualModelName) {
						const nextEntry = getCurrentEntry(nextFallbackContext(currentCtx));
						if (nextEntry) {
							updateRouteState(
								currentCtx.virtualModelName,
								currentCtx.currentIndex + 1,
								nextEntry,
								currentCtx.fallbackEntries.length,
							);
						}
					}

					currentCtx = nextFallbackContext(currentCtx);
					continue;
				}

				throw err;
			}
		}
	}

	async *dispatchStreamWithFallback(
		request: ProxyRequest,
		signal?: AbortSignal,
	): AsyncGenerator<ProxyStreamChunk> {
		await this.initialize();

		const fallbackConfig = this.config.fallbackConfig;
		if (!fallbackConfig) {
			yield* this.dispatchStream(request, signal);
			return;
		}

		const fallbackCtx = createFallbackContext(fallbackConfig, request.model, request.payload);

		if (!hasFallback(fallbackCtx)) {
			yield* this.dispatchStream(request, signal);
			return;
		}

		yield* this.executeStreamWithFallback(request, fallbackCtx, signal);
	}

	private async *executeStreamWithFallback(
		request: ProxyRequest,
		fallbackCtx: FallbackContext,
		signal?: AbortSignal,
	): AsyncGenerator<ProxyStreamChunk> {
		let currentCtx = fallbackCtx;
		const collectedChunks: Uint8Array[] = [];
		const FALLBACK_CHECK_THRESHOLD = 4096;

		while (true) {
			const entry = getCurrentEntry(currentCtx);
			if (!entry) {
				yield { payload: new Uint8Array(), error: new Error('No fallback entry available') };
				return;
			}

			const provider = mapProviderToExecutor(entry.provider);
			if (!this.executors.has(provider)) {
				if (hasMoreFallbacks(currentCtx)) {
					currentCtx = nextFallbackContext(currentCtx);
					continue;
				}
				yield {
					payload: new Uint8Array(),
					error: new Error(`Provider not available: ${provider}`),
				};
				return;
			}

			const modifiedPayload = replaceModelInPayload(currentCtx.originalPayload, entry.modelId);

			const modifiedRequest: ProxyRequest = {
				...request,
				model: entry.modelId,
				providers: [provider],
				payload: modifiedPayload,
			};

			if (this.config.debug) {
				console.log(
					`[dispatcher] Trying fallback stream ${currentCtx.currentIndex + 1}/${currentCtx.fallbackEntries.length}: ${entry.provider} → ${entry.modelId}`,
				);
			}

			let shouldRetry = false;
			let totalBytes = 0;
			collectedChunks.length = 0;

			try {
				for await (const chunk of this.dispatchStream(modifiedRequest, signal)) {
					if (chunk.error) {
						const statusCode =
							chunk.error instanceof StatusError ? (chunk.error as StatusError).statusCode : 500;

						if (
							totalBytes <= FALLBACK_CHECK_THRESHOLD &&
							shouldTriggerFallback(statusCode, chunk.error.message) &&
							hasMoreFallbacks(currentCtx)
						) {
							shouldRetry = true;
							break;
						}

						yield chunk;
						return;
					}

					totalBytes += chunk.payload.length;

					if (totalBytes <= FALLBACK_CHECK_THRESHOLD) {
						collectedChunks.push(chunk.payload);
					}

					yield chunk;

					if (chunk.done) {
						handleFallbackSuccess(currentCtx);
						if (currentCtx.virtualModelName) {
							updateRouteState(
								currentCtx.virtualModelName,
								currentCtx.currentIndex,
								entry,
								currentCtx.fallbackEntries.length,
							);
						}
						return;
					}
				}
			} catch (err) {
				const statusCode = err instanceof StatusError ? err.statusCode : 500;
				const responseBody = err instanceof Error ? err.message : '';

				if (
					totalBytes <= FALLBACK_CHECK_THRESHOLD &&
					shouldTriggerFallback(statusCode, responseBody) &&
					hasMoreFallbacks(currentCtx)
				) {
					shouldRetry = true;
				} else {
					yield {
						payload: new Uint8Array(),
						error: err instanceof Error ? err : new Error(String(err)),
					};
					return;
				}
			}

			if (shouldRetry) {
				if (this.config.debug) {
					console.log('[dispatcher] Stream fallback triggered, trying next entry');
				}

				if (currentCtx.virtualModelName) {
					const nextEntry = getCurrentEntry(nextFallbackContext(currentCtx));
					if (nextEntry) {
						updateRouteState(
							currentCtx.virtualModelName,
							currentCtx.currentIndex + 1,
							nextEntry,
							currentCtx.fallbackEntries.length,
						);
					}
				}

				currentCtx = nextFallbackContext(currentCtx);
				continue;
			}

			return;
		}
	}

	private resolveProviders(request: ProxyRequest): string[] {
		// Use explicit providers if provided
		if (request.providers.length > 0) {
			return request.providers.filter((p) => this.executors.has(p));
		}

		// Infer from model name
		const inferred = inferProviderFromModel(request.model);
		if (inferred && this.executors.has(inferred)) {
			return [inferred];
		}

		// Fallback to all available providers
		return [...this.executors.keys()];
	}

	private getModelsForProvider(provider: string): string[] {
		// Return well-known models for each provider
		switch (provider) {
			case 'claude':
				return [
					'claude-3-5-sonnet-20241022',
					'claude-3-5-haiku-20241022',
					'claude-3-opus-20240229',
					'claude-sonnet-4-20250514',
					'claude-opus-4-20250514',
				];
			case 'gemini':
				return [
					'gemini-2.0-flash-exp',
					'gemini-2.0-flash-thinking-exp',
					'gemini-1.5-pro',
					'gemini-1.5-flash',
				];
			case 'openai':
				return ['gpt-4o', 'gpt-4o-mini', 'o1', 'o1-mini', 'o3', 'o3-mini'];
			case 'copilot':
				return ['gpt-4o', 'gpt-4o-mini', 'claude-3.5-sonnet', 'o1', 'o1-mini'];
			case 'qwen':
				return ['qwen-turbo', 'qwen-plus', 'qwen-max', 'qwen-coder-turbo', 'qwen-coder-plus'];
			case 'iflow':
				return ['claude-3-5-sonnet', 'claude-3-opus', 'gpt-4o', 'gpt-4-turbo'];
			default:
				return [];
		}
	}
}

/**
 * Dispatch error with HTTP status
 */
export class DispatchError extends Error {
	constructor(
		public statusCode: number,
		message: string,
		public details?: Record<string, unknown>,
	) {
		super(message);
		this.name = 'DispatchError';
	}
}
