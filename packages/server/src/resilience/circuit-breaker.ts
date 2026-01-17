/**
 * Circuit breaker implementation for resilience
 * @packageDocumentation
 */

/**
 * Circuit breaker states
 */
export type CircuitState = "closed" | "open" | "half-open";

/**
 * Circuit breaker configuration
 */
export interface CircuitBreakerConfig {
	/** Number of failures before opening circuit */
	failureThreshold: number;
	/** Time in ms before attempting reset */
	resetTimeout: number;
	/** Number of successes in half-open to close */
	successThreshold: number;
	/** Optional: failure rate threshold (0-1) */
	failureRateThreshold?: number;
	/** Window size for failure rate calculation */
	windowSize?: number;
}

/**
 * Circuit breaker statistics
 */
export interface CircuitStats {
	state: CircuitState;
	failures: number;
	successes: number;
	lastFailure?: Date;
	lastSuccess?: Date;
	openedAt?: Date;
}

/**
 * Circuit breaker error
 */
export class CircuitOpenError extends Error {
	constructor(
		public readonly circuitId: string,
		public readonly retryAfter: number,
	) {
		super(`Circuit ${circuitId} is open. Retry after ${retryAfter}ms`);
		this.name = "CircuitOpenError";
	}
}

/**
 * Circuit breaker for preventing cascading failures
 */
export class CircuitBreaker {
	private state: CircuitState = "closed";
	private failures = 0;
	private successes = 0;
	private lastFailure?: Date;
	private lastSuccess?: Date;
	private openedAt?: Date;
	private config: Required<CircuitBreakerConfig>;
	private recentResults: boolean[] = [];

	constructor(
		private readonly id: string,
		config: CircuitBreakerConfig,
	) {
		this.config = {
			failureThreshold: config.failureThreshold,
			resetTimeout: config.resetTimeout,
			successThreshold: config.successThreshold,
			failureRateThreshold: config.failureRateThreshold ?? 0.5,
			windowSize: config.windowSize ?? 10,
		};
	}

	/**
	 * Execute a function with circuit breaker protection
	 */
	async execute<T>(fn: () => Promise<T>): Promise<T> {
		if (!this.canExecute()) {
			throw new CircuitOpenError(this.id, this.getRetryAfter());
		}

		try {
			const result = await fn();
			this.recordSuccess();
			return result;
		} catch (error) {
			this.recordFailure();
			throw error;
		}
	}

	/**
	 * Check if execution is allowed
	 */
	canExecute(): boolean {
		if (this.state === "closed") {
			return true;
		}

		if (this.state === "open") {
			// Check if reset timeout has passed
			if (this.openedAt) {
				const elapsed = Date.now() - this.openedAt.getTime();
				if (elapsed >= this.config.resetTimeout) {
					this.transitionTo("half-open");
					return true;
				}
			}
			return false;
		}

		// Half-open: allow execution to test recovery
		return true;
	}

	/**
	 * Record a successful execution
	 */
	recordSuccess(): void {
		this.successes++;
		this.lastSuccess = new Date();
		this.recentResults.push(true);
		this.trimWindow();

		if (this.state === "half-open") {
			if (this.successes >= this.config.successThreshold) {
				this.transitionTo("closed");
			}
		}
	}

	/**
	 * Record a failed execution
	 */
	recordFailure(): void {
		this.failures++;
		this.lastFailure = new Date();
		this.recentResults.push(false);
		this.trimWindow();

		if (this.state === "half-open") {
			// Any failure in half-open reopens the circuit
			this.transitionTo("open");
		} else if (this.state === "closed") {
			// Check if we should open
			if (this.shouldOpen()) {
				this.transitionTo("open");
			}
		}
	}

	/**
	 * Get circuit statistics
	 */
	getStats(): CircuitStats {
		return {
			state: this.state,
			failures: this.failures,
			successes: this.successes,
			lastFailure: this.lastFailure,
			lastSuccess: this.lastSuccess,
			openedAt: this.openedAt,
		};
	}

	/**
	 * Get retry after time in ms
	 */
	getRetryAfter(): number {
		if (this.state !== "open" || !this.openedAt) {
			return 0;
		}
		const elapsed = Date.now() - this.openedAt.getTime();
		return Math.max(0, this.config.resetTimeout - elapsed);
	}

	/**
	 * Reset the circuit breaker
	 */
	reset(): void {
		this.state = "closed";
		this.failures = 0;
		this.successes = 0;
		this.lastFailure = undefined;
		this.lastSuccess = undefined;
		this.openedAt = undefined;
		this.recentResults = [];
	}

	/**
	 * Force open the circuit
	 */
	trip(): void {
		this.transitionTo("open");
	}

	private shouldOpen(): boolean {
		// Check failure threshold
		if (this.failures >= this.config.failureThreshold) {
			return true;
		}

		// Check failure rate if we have enough data
		if (this.recentResults.length >= this.config.windowSize) {
			const failures = this.recentResults.filter((r) => !r).length;
			const rate = failures / this.recentResults.length;
			if (rate >= this.config.failureRateThreshold) {
				return true;
			}
		}

		return false;
	}

	private transitionTo(newState: CircuitState): void {
		const oldState = this.state;
		this.state = newState;

		if (newState === "open") {
			this.openedAt = new Date();
		} else if (newState === "closed") {
			this.failures = 0;
			this.successes = 0;
			this.openedAt = undefined;
		} else if (newState === "half-open") {
			this.successes = 0;
		}

		// Could emit event here for monitoring
		if (oldState !== newState) {
			// console.log(`[circuit-breaker] ${this.id}: ${oldState} -> ${newState}`);
		}
	}

	private trimWindow(): void {
		while (this.recentResults.length > this.config.windowSize) {
			this.recentResults.shift();
		}
	}
}

/**
 * Circuit breaker registry for managing multiple circuits
 */
export class CircuitBreakerRegistry {
	private circuits: Map<string, CircuitBreaker> = new Map();
	private defaultConfig: CircuitBreakerConfig;

	constructor(defaultConfig?: Partial<CircuitBreakerConfig>) {
		this.defaultConfig = {
			failureThreshold: defaultConfig?.failureThreshold ?? 5,
			resetTimeout: defaultConfig?.resetTimeout ?? 30000,
			successThreshold: defaultConfig?.successThreshold ?? 3,
			failureRateThreshold: defaultConfig?.failureRateThreshold ?? 0.5,
			windowSize: defaultConfig?.windowSize ?? 10,
		};
	}

	/**
	 * Get or create a circuit breaker
	 */
	get(id: string, config?: Partial<CircuitBreakerConfig>): CircuitBreaker {
		let circuit = this.circuits.get(id);

		if (!circuit) {
			circuit = new CircuitBreaker(id, {
				...this.defaultConfig,
				...config,
			});
			this.circuits.set(id, circuit);
		}

		return circuit;
	}

	/**
	 * Get all circuit statistics
	 */
	getAllStats(): Map<string, CircuitStats> {
		const stats = new Map<string, CircuitStats>();
		for (const [id, circuit] of this.circuits) {
			stats.set(id, circuit.getStats());
		}
		return stats;
	}

	/**
	 * Reset all circuits
	 */
	resetAll(): void {
		for (const circuit of this.circuits.values()) {
			circuit.reset();
		}
	}

	/**
	 * Remove a circuit
	 */
	remove(id: string): boolean {
		return this.circuits.delete(id);
	}
}
