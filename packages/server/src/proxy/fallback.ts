/**
 * Fallback support for virtual model routing
 *
 * When a virtual model is detected, resolves it to real models and automatically
 * retries on quota exhaustion (429/5xx errors).
 *
 * This replaces the Swift ProxyBridge fallback logic.
 *
 * @packageDocumentation
 */

import type {
	CachedEntryInfo,
	FallbackConfiguration,
	FallbackEntry,
	FallbackRouteState,
} from '@quotio/core';
import { findVirtualModel, getSortedEntries, isCacheValid, isVirtualModel } from '@quotio/core';

// MARK: - Fallback Context

/**
 * Context for tracking fallback state during request processing
 */
export interface FallbackContext {
	/** Original virtual model name (null if not using fallback) */
	virtualModelName: string | null;
	/** Ordered list of fallback entries */
	fallbackEntries: FallbackEntry[];
	/** Current index in the fallback chain (0-based) */
	currentIndex: number;
	/** Original request body (for retry with different model) */
	originalPayload: Uint8Array;
	/** Whether the current entry was loaded from cache */
	wasLoadedFromCache: boolean;
}

/**
 * Empty fallback context for non-virtual-model requests
 */
export const EMPTY_FALLBACK_CONTEXT: Readonly<FallbackContext> = Object.freeze({
	virtualModelName: null,
	fallbackEntries: [],
	currentIndex: 0,
	originalPayload: new Uint8Array(),
	wasLoadedFromCache: false,
});

/**
 * Check if context has fallback enabled
 */
export function hasFallback(ctx: FallbackContext): boolean {
	return ctx.fallbackEntries.length > 0;
}

/**
 * Check if there are more fallbacks to try
 */
export function hasMoreFallbacks(ctx: FallbackContext): boolean {
	return ctx.currentIndex + 1 < ctx.fallbackEntries.length;
}

/**
 * Get current fallback entry
 */
export function getCurrentEntry(ctx: FallbackContext): FallbackEntry | null {
	if (ctx.currentIndex >= ctx.fallbackEntries.length) {
		return null;
	}
	return ctx.fallbackEntries[ctx.currentIndex] ?? null;
}

/**
 * Create next fallback context (advance to next entry)
 */
export function nextFallbackContext(ctx: FallbackContext): FallbackContext {
	return {
		...ctx,
		currentIndex: ctx.currentIndex + 1,
		wasLoadedFromCache: false,
	};
}

// MARK: - Fallback Service

/**
 * In-memory cache for successful fallback entries
 * Key: virtual model name, Value: cached entry info
 */
const entryIdCache = new Map<string, CachedEntryInfo>();

/**
 * In-memory route states for UI display
 * Key: virtual model name, Value: current route state
 */
const routeStates = new Map<string, FallbackRouteState>();

/**
 * Get cached entry ID for a virtual model
 */
export function getCachedEntryId(virtualModelName: string): string | null {
	const cached = entryIdCache.get(virtualModelName);
	if (!cached) {
		return null;
	}

	if (!isCacheValid(cached)) {
		entryIdCache.delete(virtualModelName);
		return null;
	}

	return cached.entryId;
}

/**
 * Cache a successful entry ID for a virtual model
 */
export function setCachedEntryId(virtualModelName: string, entryId: string): void {
	entryIdCache.set(virtualModelName, {
		entryId,
		cachedAt: new Date(),
	});
}

/**
 * Clear cached entry ID for a virtual model
 */
export function clearCachedEntryId(virtualModelName: string): void {
	entryIdCache.delete(virtualModelName);
}

/**
 * Update route state for UI display
 */
export function updateRouteState(
	virtualModelName: string,
	entryIndex: number,
	entry: FallbackEntry,
	totalEntries: number,
): void {
	routeStates.set(virtualModelName, {
		virtualModelName,
		currentEntryIndex: entryIndex,
		currentEntry: entry,
		lastUpdated: new Date(),
		totalEntries,
	});
}

/**
 * Get route state for a virtual model
 */
export function getRouteState(virtualModelName: string): FallbackRouteState | null {
	return routeStates.get(virtualModelName) ?? null;
}

/**
 * Get all route states
 */
export function getAllRouteStates(): FallbackRouteState[] {
	return Array.from(routeStates.values()).sort((a, b) =>
		a.virtualModelName.localeCompare(b.virtualModelName),
	);
}

/**
 * Clear route state for a virtual model
 */
export function clearRouteState(virtualModelName: string): void {
	routeStates.delete(virtualModelName);
	entryIdCache.delete(virtualModelName);
}

/**
 * Clear all route states
 */
export function clearAllRouteStates(): void {
	routeStates.clear();
	entryIdCache.clear();
}

// MARK: - Fallback Context Creation

/**
 * Create fallback context from request
 *
 * @param config - Fallback configuration
 * @param model - Model name from request
 * @param payload - Original request payload
 * @returns Fallback context (empty if not a virtual model)
 */
export function createFallbackContext(
	config: FallbackConfiguration,
	model: string,
	payload: Uint8Array,
): FallbackContext {
	// Check if fallback is globally enabled
	if (!config.isEnabled) {
		return { ...EMPTY_FALLBACK_CONTEXT };
	}

	// Check if this is a virtual model
	if (!isVirtualModel(config, model)) {
		return { ...EMPTY_FALLBACK_CONTEXT };
	}

	// Find the virtual model
	const virtualModel = findVirtualModel(config, model);
	if (!virtualModel) {
		return { ...EMPTY_FALLBACK_CONTEXT };
	}

	// Get sorted entries
	const entries = getSortedEntries(virtualModel);
	if (entries.length === 0) {
		return { ...EMPTY_FALLBACK_CONTEXT };
	}

	// Check for cached entry and find its index
	let startIndex = 0;
	let wasLoadedFromCache = false;

	const cachedEntryId = getCachedEntryId(model);
	if (cachedEntryId) {
		const cachedIndex = entries.findIndex((e) => e.id === cachedEntryId);
		if (cachedIndex !== -1) {
			startIndex = cachedIndex;
			wasLoadedFromCache = true;
		}
	}

	return {
		virtualModelName: model,
		fallbackEntries: entries,
		currentIndex: startIndex,
		originalPayload: payload,
		wasLoadedFromCache,
	};
}

// MARK: - Error Detection

/**
 * HTTP status codes that should trigger fallback
 */
const FALLBACK_STATUS_CODES = new Set([429, 503, 500, 400, 401, 403, 422]);

/**
 * Error patterns in response body that should trigger fallback
 */
const ERROR_PATTERNS = [
	'quota exceeded',
	'rate limit',
	'limit reached',
	'no available account',
	'insufficient_quota',
	'resource_exhausted',
	'overloaded',
	'capacity',
	'too many requests',
	'throttl',
	'invalid_request',
	'bad request',
	'authentication',
	'unauthorized',
	'invalid api key',
	'access denied',
	'model not found',
	'model unavailable',
	'does not exist',
];

/**
 * Check if an HTTP status code should trigger fallback
 */
export function shouldFallbackOnStatus(statusCode: number): boolean {
	return FALLBACK_STATUS_CODES.has(statusCode);
}

/**
 * Check if response body contains error patterns that should trigger fallback
 *
 * @param responseBody - Response body as string (first 4KB)
 */
export function shouldFallbackOnBody(responseBody: string): boolean {
	const lowercased = responseBody.toLowerCase();

	for (const pattern of ERROR_PATTERNS) {
		if (lowercased.includes(pattern)) {
			return true;
		}
	}

	return false;
}

/**
 * Check if a response should trigger fallback
 *
 * @param statusCode - HTTP status code
 * @param responseBody - Optional response body preview (first 4KB)
 */
export function shouldTriggerFallback(statusCode: number, responseBody?: string): boolean {
	// Check status code first
	if (shouldFallbackOnStatus(statusCode)) {
		return true;
	}

	// Success responses don't trigger fallback
	if (statusCode >= 200 && statusCode < 300) {
		return false;
	}

	// Check response body for error patterns
	if (responseBody) {
		return shouldFallbackOnBody(responseBody);
	}

	return false;
}

// MARK: - Model Replacement

/**
 * Replace model name in request payload
 *
 * @param payload - Original request payload
 * @param newModel - New model name to use
 * @returns Modified payload with new model name
 */
export function replaceModelInPayload(payload: Uint8Array, newModel: string): Uint8Array {
	try {
		const text = new TextDecoder().decode(payload);
		const json = JSON.parse(text) as Record<string, unknown>;

		if (typeof json.model !== 'string') {
			return payload;
		}

		const originalModel = json.model;
		// Simple string replacement to preserve JSON format
		const modified = text.replace(`"${originalModel}"`, `"${newModel}"`);

		return new TextEncoder().encode(modified);
	} catch {
		// If parsing fails, return original payload
		return payload;
	}
}

/**
 * Extract model name from request payload
 */
export function extractModelFromPayload(payload: Uint8Array): string | null {
	try {
		const text = new TextDecoder().decode(payload);
		const json = JSON.parse(text) as Record<string, unknown>;
		return typeof json.model === 'string' ? json.model : null;
	} catch {
		return null;
	}
}

// MARK: - Success Handling

/**
 * Handle successful fallback completion
 *
 * Caches the successful entry ID for future requests
 */
export function handleFallbackSuccess(ctx: FallbackContext): void {
	// Only cache if:
	// 1. Fallback was triggered (currentIndex > 0)
	// 2. Entry was NOT loaded from cache
	// 3. We have a valid virtual model name and entry
	if (ctx.currentIndex > 0 && !ctx.wasLoadedFromCache && ctx.virtualModelName) {
		const currentEntry = getCurrentEntry(ctx);
		if (currentEntry) {
			setCachedEntryId(ctx.virtualModelName, currentEntry.id);
			updateRouteState(
				ctx.virtualModelName,
				ctx.currentIndex,
				currentEntry,
				ctx.fallbackEntries.length,
			);
		}
	}
}

// MARK: - Provider Mapping

/**
 * Map fallback entry provider to executor provider ID
 */
export function mapProviderToExecutor(provider: string): string {
	// Provider IDs are lowercase
	return provider.toLowerCase();
}
