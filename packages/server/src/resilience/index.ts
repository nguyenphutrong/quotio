/**
 * Resilience module exports
 * @packageDocumentation
 */

// Circuit Breaker
export type {
	CircuitState,
	CircuitBreakerConfig,
	CircuitStats,
} from "./circuit-breaker.js";

export {
	CircuitBreaker,
	CircuitBreakerRegistry,
	CircuitOpenError,
} from "./circuit-breaker.js";

// Retry
export type {
	RetryConfig,
	RetryAttempt,
	RetryResult,
} from "./retry.js";

export {
	DEFAULT_RETRY_CONFIG,
	RetryExhaustedError,
	HttpStatusError,
	withRetry,
	withRetryResult,
	retryable,
} from "./retry.js";

// Timeout
export type { TimeoutConfig } from "./timeout.js";

export {
	DEFAULT_TIMEOUT_CONFIG,
	TimeoutError,
	withTimeout,
	withTimeoutSignal,
	createTimeoutSignal,
	combineSignals,
	createDeadline,
	isDeadlinePassed,
	getRemainingTime,
	fetchWithTimeout,
	raceWithTimeout,
	withDeadline,
} from "./timeout.js";
