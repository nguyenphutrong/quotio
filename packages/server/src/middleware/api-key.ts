/**
 * API Key authentication middleware
 * @packageDocumentation
 */

import type { Context, MiddlewareHandler } from "hono";
import { HTTPException } from "hono/http-exception";

/**
 * API Key configuration
 */
export interface ApiKeyConfig {
	/** Header name for API key */
	headerName: string;
	/** Query parameter name for API key (optional) */
	queryParam?: string;
	/** Prefix for API key (e.g., "Bearer ") */
	prefix?: string;
	/** Skip authentication for these paths */
	skipPaths?: string[];
	/** Custom key validator */
	validate: (key: string) => Promise<ApiKeyValidation>;
}

/**
 * API Key validation result
 */
export interface ApiKeyValidation {
	valid: boolean;
	keyId?: string;
	metadata?: Record<string, unknown>;
	error?: string;
}

/**
 * Context with API key info
 */
export interface ApiKeyContext {
	keyId: string;
	metadata?: Record<string, unknown>;
}

/**
 * Default configuration
 */
const DEFAULT_CONFIG: Partial<ApiKeyConfig> = {
	headerName: "X-API-Key",
	queryParam: "api_key",
	prefix: "",
	skipPaths: ["/health", "/healthz", "/ready"],
};

/**
 * API Key authentication middleware factory
 */
export function apiKeyAuth(config: ApiKeyConfig): MiddlewareHandler {
	const cfg = { ...DEFAULT_CONFIG, ...config };

	return async (c: Context, next) => {
		// Check skip paths
		if (cfg.skipPaths?.some((path) => c.req.path.startsWith(path))) {
			return next();
		}

		// Extract API key
		const key = extractApiKey(c, cfg);

		if (!key) {
			throw new HTTPException(401, {
				message: "API key required",
			});
		}

		// Validate API key
		const validation = await cfg.validate(key);

		if (!validation.valid) {
			throw new HTTPException(401, {
				message: validation.error ?? "Invalid API key",
			});
		}

		// Store in context
		c.set("apiKey", {
			keyId: validation.keyId,
			metadata: validation.metadata,
		} as ApiKeyContext);

		return next();
	};
}

/**
 * Extract API key from request
 */
function extractApiKey(c: Context, config: Partial<ApiKeyConfig>): string | null {
	// Try header first
	let key = c.req.header(config.headerName ?? "X-API-Key");

	// Try Authorization header with Bearer prefix
	if (!key) {
		const authHeader = c.req.header("Authorization");
		if (authHeader?.startsWith("Bearer ")) {
			key = authHeader.slice(7);
		}
	}

	// Try query parameter
	if (!key && config.queryParam) {
		key = c.req.query(config.queryParam);
	}

	// Remove prefix if configured
	if (key && config.prefix) {
		if (key.startsWith(config.prefix)) {
			key = key.slice(config.prefix.length);
		}
	}

	return key || null;
}

/**
 * Get API key context from Hono context
 */
export function getApiKeyContext(c: Context): ApiKeyContext | undefined {
	return c.get("apiKey") as ApiKeyContext | undefined;
}

/**
 * Simple in-memory API key store for development
 */
export class InMemoryApiKeyStore {
	private keys: Map<string, { id: string; metadata?: Record<string, unknown> }> =
		new Map();

	/**
	 * Add an API key
	 */
	add(key: string, id: string, metadata?: Record<string, unknown>): void {
		this.keys.set(key, { id, metadata });
	}

	/**
	 * Remove an API key
	 */
	remove(key: string): boolean {
		return this.keys.delete(key);
	}

	/**
	 * Validate an API key
	 */
	async validate(key: string): Promise<ApiKeyValidation> {
		const entry = this.keys.get(key);

		if (!entry) {
			return { valid: false, error: "Invalid API key" };
		}

		return {
			valid: true,
			keyId: entry.id,
			metadata: entry.metadata,
		};
	}

	/**
	 * Create middleware with this store
	 */
	middleware(options?: Partial<Omit<ApiKeyConfig, "validate">>): MiddlewareHandler {
		return apiKeyAuth({
			headerName: options?.headerName ?? "X-API-Key",
			queryParam: options?.queryParam,
			prefix: options?.prefix,
			skipPaths: options?.skipPaths,
			validate: (key) => this.validate(key),
		});
	}
}

/**
 * Create a hash of an API key for storage
 */
export async function hashApiKey(key: string): Promise<string> {
	const encoder = new TextEncoder();
	const data = encoder.encode(key);
	const hashBuffer = await crypto.subtle.digest("SHA-256", data);
	const hashArray = Array.from(new Uint8Array(hashBuffer));
	return hashArray.map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Generate a random API key
 */
export function generateApiKey(prefix = "qto"): string {
	const bytes = new Uint8Array(24);
	crypto.getRandomValues(bytes);
	const key = Array.from(bytes)
		.map((b) => b.toString(16).padStart(2, "0"))
		.join("");
	return `${prefix}_${key}`;
}
