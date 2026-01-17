/**
 * Retry logic with exponential backoff
 * @packageDocumentation
 */

/**
 * Retry configuration
 */
export interface RetryConfig {
	/** Maximum number of retry attempts */
	maxAttempts: number;
	/** Initial delay in ms */
	initialDelay: number;
	/** Maximum delay in ms */
	maxDelay: number;
	/** Backoff multiplier */
	backoffMultiplier: number;
	/** Add jitter to delays */
	jitter: boolean;
	/** HTTP status codes that should trigger retry */
	retryableStatusCodes: number[];
	/** Custom retry predicate */
	shouldRetry?: (error: unknown, attempt: number) => boolean;
}

/**
 * Retry attempt info
 */
export interface RetryAttempt {
	attempt: number;
	maxAttempts: number;
	delay: number;
	error?: Error;
}

/**
 * Retry result
 */
export interface RetryResult<T> {
	success: boolean;
	result?: T;
	error?: Error;
	attempts: number;
	totalDelay: number;
}

/**
 * Default retry configuration
 */
export const DEFAULT_RETRY_CONFIG: RetryConfig = {
	maxAttempts: 3,
	initialDelay: 1000,
	maxDelay: 30000,
	backoffMultiplier: 2,
	jitter: true,
	retryableStatusCodes: [429, 500, 502, 503, 504],
};

/**
 * Retry error with attempt info
 */
export class RetryExhaustedError extends Error {
	constructor(
		public readonly attempts: number,
		public readonly lastError: Error,
	) {
		super(`Retry exhausted after ${attempts} attempts: ${lastError.message}`);
		this.name = "RetryExhaustedError";
	}
}

/**
 * HTTP status error for retry decisions
 */
export class HttpStatusError extends Error {
	constructor(
		public readonly status: number,
		message: string,
		public readonly retryAfter?: number,
	) {
		super(message);
		this.name = "HttpStatusError";
	}
}

/**
 * Execute a function with retry logic
 */
export async function withRetry<T>(
	fn: () => Promise<T>,
	config: Partial<RetryConfig> = {},
): Promise<T> {
	const cfg: RetryConfig = { ...DEFAULT_RETRY_CONFIG, ...config };
	let lastError: Error | undefined;
	let totalDelay = 0;

	for (let attempt = 1; attempt <= cfg.maxAttempts; attempt++) {
		try {
			return await fn();
		} catch (error) {
			lastError = error instanceof Error ? error : new Error(String(error));

			// Check if we should retry
			if (attempt >= cfg.maxAttempts) {
				break;
			}

			if (!shouldRetryError(lastError, attempt, cfg)) {
				break;
			}

			// Calculate delay
			const delay = calculateDelay(attempt, lastError, cfg);
			totalDelay += delay;

			// Wait before retry
			await sleep(delay);
		}
	}

	throw new RetryExhaustedError(cfg.maxAttempts, lastError!);
}

/**
 * Execute with retry and return detailed result
 */
export async function withRetryResult<T>(
	fn: () => Promise<T>,
	config: Partial<RetryConfig> = {},
): Promise<RetryResult<T>> {
	const cfg: RetryConfig = { ...DEFAULT_RETRY_CONFIG, ...config };
	let lastError: Error | undefined;
	let totalDelay = 0;
	let attempts = 0;

	for (let attempt = 1; attempt <= cfg.maxAttempts; attempt++) {
		attempts = attempt;

		try {
			const result = await fn();
			return {
				success: true,
				result,
				attempts,
				totalDelay,
			};
		} catch (error) {
			lastError = error instanceof Error ? error : new Error(String(error));

			if (attempt >= cfg.maxAttempts) {
				break;
			}

			if (!shouldRetryError(lastError, attempt, cfg)) {
				break;
			}

			const delay = calculateDelay(attempt, lastError, cfg);
			totalDelay += delay;
			await sleep(delay);
		}
	}

	return {
		success: false,
		error: lastError,
		attempts,
		totalDelay,
	};
}

/**
 * Create a retryable version of a function
 */
export function retryable<TArgs extends unknown[], TResult>(
	fn: (...args: TArgs) => Promise<TResult>,
	config: Partial<RetryConfig> = {},
): (...args: TArgs) => Promise<TResult> {
	return (...args: TArgs) => withRetry(() => fn(...args), config);
}

/**
 * Check if an error should trigger a retry
 */
function shouldRetryError(
	error: Error,
	attempt: number,
	config: RetryConfig,
): boolean {
	// Custom predicate takes precedence
	if (config.shouldRetry) {
		return config.shouldRetry(error, attempt);
	}

	// Check HTTP status errors
	if (error instanceof HttpStatusError) {
		return config.retryableStatusCodes.includes(error.status);
	}

	// Check for network errors
	if (isNetworkError(error)) {
		return true;
	}

	// Check for timeout errors
	if (isTimeoutError(error)) {
		return true;
	}

	return false;
}

/**
 * Calculate delay for next retry attempt
 */
function calculateDelay(
	attempt: number,
	error: Error,
	config: RetryConfig,
): number {
	// Respect retry-after header if present
	if (error instanceof HttpStatusError && error.retryAfter) {
		return Math.min(error.retryAfter * 1000, config.maxDelay);
	}

	// Exponential backoff
	let delay = config.initialDelay * Math.pow(config.backoffMultiplier, attempt - 1);

	// Apply max delay cap
	delay = Math.min(delay, config.maxDelay);

	// Add jitter if enabled
	if (config.jitter) {
		delay = addJitter(delay);
	}

	return delay;
}

/**
 * Add random jitter to delay (+/- 25%)
 */
function addJitter(delay: number): number {
	const jitterFactor = 0.25;
	const jitter = delay * jitterFactor * (Math.random() * 2 - 1);
	return Math.max(0, Math.floor(delay + jitter));
}

/**
 * Check if error is a network error
 */
function isNetworkError(error: Error): boolean {
	const networkErrorMessages = [
		"ECONNRESET",
		"ECONNREFUSED",
		"ETIMEDOUT",
		"ENOTFOUND",
		"ENETUNREACH",
		"EAI_AGAIN",
		"fetch failed",
		"network error",
	];

	const message = error.message.toLowerCase();
	return networkErrorMessages.some((msg) =>
		message.includes(msg.toLowerCase()),
	);
}

/**
 * Check if error is a timeout error
 */
function isTimeoutError(error: Error): boolean {
	const message = error.message.toLowerCase();
	return (
		message.includes("timeout") ||
		message.includes("timed out") ||
		error.name === "TimeoutError"
	);
}

/**
 * Sleep for specified milliseconds
 */
function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}
