/**
 * Proxy dispatcher
 *
 * Routes requests to appropriate provider executors via CredentialPool.
 * @packageDocumentation
 */

import type { TokenStore } from "../store/types.js";
import {
	CredentialPool,
	RoundRobinSelector,
	ClaudeExecutor,
	GeminiExecutor,
	OpenAIExecutor,
	CopilotExecutor,
	QwenExecutor,
	IFlowExecutor,
	type ProviderExecutor,
	type ExecutorRequest,
	type ExecutorOptions,
} from "../executor/index.js";
import type { ProxyRequest } from "./types.js";
import { inferProviderFromModel } from "./types.js";

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
	/** Default max tokens if not specified */
	defaultMaxTokens?: number;
	/** Enable debug logging */
	debug?: boolean;
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
		};

		// Initialize credential pool with round-robin selection
		this.pool = new CredentialPool({
			store,
			selector: new RoundRobinSelector(),
		});

		// Register default executors
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
			console.log("[dispatcher] initialized with executors:", [...this.executors.keys()]);
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
			throw new DispatchError(400, "No provider available for model: " + request.model);
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
				console.error("[dispatcher] dispatch error:", err);
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
			yield { payload: new Uint8Array(), error: new Error("No provider available") };
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
			if (auth.disabled || auth.status === "error") continue;

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
			case "claude":
				return [
					"claude-3-5-sonnet-20241022",
					"claude-3-5-haiku-20241022",
					"claude-3-opus-20240229",
					"claude-sonnet-4-20250514",
					"claude-opus-4-20250514",
				];
			case "gemini":
				return [
					"gemini-2.0-flash-exp",
					"gemini-2.0-flash-thinking-exp",
					"gemini-1.5-pro",
					"gemini-1.5-flash",
				];
			case "openai":
				return ["gpt-4o", "gpt-4o-mini", "o1", "o1-mini", "o3", "o3-mini"];
			case "copilot":
				return ["gpt-4o", "gpt-4o-mini", "claude-3.5-sonnet", "o1", "o1-mini"];
			case "qwen":
				return [
					"qwen-turbo",
					"qwen-plus",
					"qwen-max",
					"qwen-coder-turbo",
					"qwen-coder-plus",
				];
			case "iflow":
				return [
					"claude-3-5-sonnet",
					"claude-3-opus",
					"gpt-4o",
					"gpt-4-turbo",
				];
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
		this.name = "DispatchError";
	}
}
