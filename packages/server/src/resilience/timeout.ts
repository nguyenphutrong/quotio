/**
 * Timeout utilities for request handling
 * @packageDocumentation
 */

/**
 * Timeout configuration
 */
export interface TimeoutConfig {
	/** Request timeout in ms */
	requestTimeout: number;
	/** Connection timeout in ms */
	connectTimeout: number;
	/** Idle timeout in ms */
	idleTimeout: number;
}

/**
 * Default timeout configuration
 */
export const DEFAULT_TIMEOUT_CONFIG: TimeoutConfig = {
	requestTimeout: 120000, // 2 minutes
	connectTimeout: 10000, // 10 seconds
	idleTimeout: 30000, // 30 seconds
};

/**
 * Timeout error
 */
export class TimeoutError extends Error {
	constructor(
		public readonly timeoutMs: number,
		public readonly operation: string = "operation",
	) {
		super(`${operation} timed out after ${timeoutMs}ms`);
		this.name = "TimeoutError";
	}
}

/**
 * Execute a function with timeout
 */
export async function withTimeout<T>(
	fn: () => Promise<T>,
	timeoutMs: number,
	operation = "operation",
): Promise<T> {
	const controller = new AbortController();
	const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

	try {
		const result = await Promise.race([
			fn(),
			createTimeoutPromise(timeoutMs, operation),
		]);
		return result as T;
	} finally {
		clearTimeout(timeoutId);
	}
}

/**
 * Execute a function with AbortSignal-based timeout
 */
export async function withTimeoutSignal<T>(
	fn: (signal: AbortSignal) => Promise<T>,
	timeoutMs: number,
	operation = "operation",
): Promise<T> {
	const controller = new AbortController();
	const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

	try {
		const result = await Promise.race([
			fn(controller.signal),
			createTimeoutPromise(timeoutMs, operation),
		]);
		return result as T;
	} finally {
		clearTimeout(timeoutId);
	}
}

/**
 * Create an AbortSignal that times out
 */
export function createTimeoutSignal(timeoutMs: number): AbortSignal {
	const controller = new AbortController();
	setTimeout(() => controller.abort(), timeoutMs);
	return controller.signal;
}

/**
 * Combine multiple AbortSignals
 */
export function combineSignals(...signals: (AbortSignal | undefined)[]): AbortSignal {
	const controller = new AbortController();
	const validSignals = signals.filter((s): s is AbortSignal => s !== undefined);

	for (const signal of validSignals) {
		if (signal.aborted) {
			controller.abort();
			break;
		}
		signal.addEventListener("abort", () => controller.abort(), { once: true });
	}

	return controller.signal;
}

/**
 * Create a deadline (absolute timeout)
 */
export function createDeadline(durationMs: number): Date {
	return new Date(Date.now() + durationMs);
}

/**
 * Check if deadline has passed
 */
export function isDeadlinePassed(deadline: Date): boolean {
	return Date.now() >= deadline.getTime();
}

/**
 * Get remaining time until deadline
 */
export function getRemainingTime(deadline: Date): number {
	return Math.max(0, deadline.getTime() - Date.now());
}

/**
 * Wrap a fetch call with timeout
 */
export async function fetchWithTimeout(
	input: string | URL | Request,
	init?: RequestInit & { timeout?: number },
): Promise<Response> {
	const timeout = init?.timeout ?? DEFAULT_TIMEOUT_CONFIG.requestTimeout;
	const controller = new AbortController();

	// Combine with existing signal if present
	const existingSignal = init?.signal;
	if (existingSignal) {
		existingSignal.addEventListener("abort", () => controller.abort(), {
			once: true,
		});
	}

	const timeoutId = setTimeout(() => controller.abort(), timeout);

	try {
		const response = await fetch(input, {
			...init,
			signal: controller.signal,
		});
		return response;
	} catch (error) {
		if (controller.signal.aborted) {
			throw new TimeoutError(timeout, "fetch");
		}
		throw error;
	} finally {
		clearTimeout(timeoutId);
	}
}

/**
 * Create a promise that rejects after timeout
 */
function createTimeoutPromise(timeoutMs: number, operation: string): Promise<never> {
	return new Promise((_, reject) => {
		setTimeout(() => {
			reject(new TimeoutError(timeoutMs, operation));
		}, timeoutMs);
	});
}

/**
 * Race multiple promises with timeout
 */
export async function raceWithTimeout<T>(
	promises: Promise<T>[],
	timeoutMs: number,
	operation = "race",
): Promise<T> {
	return Promise.race([
		...promises,
		createTimeoutPromise(timeoutMs, operation),
	]);
}

/**
 * Execute with deadline context
 */
export async function withDeadline<T>(
	fn: (remainingMs: () => number) => Promise<T>,
	deadline: Date,
	operation = "operation",
): Promise<T> {
	const getRemainingMs = () => getRemainingTime(deadline);

	if (isDeadlinePassed(deadline)) {
		throw new TimeoutError(0, operation);
	}

	return withTimeout(
		() => fn(getRemainingMs),
		getRemainingMs(),
		operation,
	);
}
