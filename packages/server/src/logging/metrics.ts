/**
 * Simple metrics collection
 * @packageDocumentation
 */

/**
 * Counter for tracking counts
 */
export class Counter {
	private value = 0;
	private labels: Map<string, number> = new Map();

	/**
	 * Increment counter
	 */
	inc(labels?: Record<string, string>, amount = 1): void {
		this.value += amount;

		if (labels) {
			const key = this.labelsToKey(labels);
			this.labels.set(key, (this.labels.get(key) ?? 0) + amount);
		}
	}

	/**
	 * Get total value
	 */
	get(): number {
		return this.value;
	}

	/**
	 * Get value for specific labels
	 */
	getByLabels(labels: Record<string, string>): number {
		return this.labels.get(this.labelsToKey(labels)) ?? 0;
	}

	/**
	 * Get all labeled values
	 */
	getAll(): Map<string, number> {
		return new Map(this.labels);
	}

	/**
	 * Reset counter
	 */
	reset(): void {
		this.value = 0;
		this.labels.clear();
	}

	private labelsToKey(labels: Record<string, string>): string {
		return Object.entries(labels)
			.sort(([a], [b]) => a.localeCompare(b))
			.map(([k, v]) => `${k}=${v}`)
			.join(",");
	}
}

/**
 * Histogram for tracking distributions
 */
export class Histogram {
	private values: number[] = [];
	private labels: Map<string, number[]> = new Map();
	private maxSamples: number;

	constructor(maxSamples = 10000) {
		this.maxSamples = maxSamples;
	}

	/**
	 * Observe a value
	 */
	observe(value: number, labels?: Record<string, string>): void {
		this.values.push(value);
		if (this.values.length > this.maxSamples) {
			this.values.shift();
		}

		if (labels) {
			const key = this.labelsToKey(labels);
			const arr = this.labels.get(key) ?? [];
			arr.push(value);
			if (arr.length > this.maxSamples / 10) {
				arr.shift();
			}
			this.labels.set(key, arr);
		}
	}

	/**
	 * Get statistics
	 */
	getStats(): HistogramStats {
		return this.calculateStats(this.values);
	}

	/**
	 * Get stats for specific labels
	 */
	getStatsByLabels(labels: Record<string, string>): HistogramStats {
		const values = this.labels.get(this.labelsToKey(labels)) ?? [];
		return this.calculateStats(values);
	}

	/**
	 * Reset histogram
	 */
	reset(): void {
		this.values = [];
		this.labels.clear();
	}

	private calculateStats(values: number[]): HistogramStats {
		if (values.length === 0) {
			return {
				count: 0,
				sum: 0,
				mean: 0,
				min: 0,
				max: 0,
				p50: 0,
				p95: 0,
				p99: 0,
			};
		}

		const sorted = [...values].sort((a, b) => a - b);
		const sum = values.reduce((a, b) => a + b, 0);

		return {
			count: values.length,
			sum,
			mean: sum / values.length,
			min: sorted[0],
			max: sorted[sorted.length - 1],
			p50: this.percentile(sorted, 0.5),
			p95: this.percentile(sorted, 0.95),
			p99: this.percentile(sorted, 0.99),
		};
	}

	private percentile(sorted: number[], p: number): number {
		const idx = Math.ceil(sorted.length * p) - 1;
		return sorted[Math.max(0, idx)];
	}

	private labelsToKey(labels: Record<string, string>): string {
		return Object.entries(labels)
			.sort(([a], [b]) => a.localeCompare(b))
			.map(([k, v]) => `${k}=${v}`)
			.join(",");
	}
}

/**
 * Histogram statistics
 */
export interface HistogramStats {
	count: number;
	sum: number;
	mean: number;
	min: number;
	max: number;
	p50: number;
	p95: number;
	p99: number;
}

/**
 * Metrics registry
 */
export class MetricsRegistry {
	private counters: Map<string, Counter> = new Map();
	private histograms: Map<string, Histogram> = new Map();

	/**
	 * Get or create a counter
	 */
	counter(name: string): Counter {
		let counter = this.counters.get(name);
		if (!counter) {
			counter = new Counter();
			this.counters.set(name, counter);
		}
		return counter;
	}

	/**
	 * Get or create a histogram
	 */
	histogram(name: string, maxSamples = 10000): Histogram {
		let histogram = this.histograms.get(name);
		if (!histogram) {
			histogram = new Histogram(maxSamples);
			this.histograms.set(name, histogram);
		}
		return histogram;
	}

	/**
	 * Get all metrics as JSON-serializable object
	 */
	toJSON(): Record<string, unknown> {
		const result: Record<string, unknown> = {};

		for (const [name, counter] of this.counters) {
			result[name] = {
				type: "counter",
				value: counter.get(),
				labels: Object.fromEntries(counter.getAll()),
			};
		}

		for (const [name, histogram] of this.histograms) {
			result[name] = {
				type: "histogram",
				stats: histogram.getStats(),
			};
		}

		return result;
	}

	/**
	 * Reset all metrics
	 */
	reset(): void {
		for (const counter of this.counters.values()) {
			counter.reset();
		}
		for (const histogram of this.histograms.values()) {
			histogram.reset();
		}
	}
}

/**
 * Default metrics for proxy server
 */
export interface ProxyMetrics {
	/** Total requests */
	requestsTotal: Counter;
	/** Requests by status */
	requestsByStatus: Counter;
	/** Requests by provider */
	requestsByProvider: Counter;
	/** Request duration */
	requestDuration: Histogram;
	/** Active connections */
	activeConnections: Counter;
	/** Token usage */
	tokensUsed: Counter;
}

/**
 * Create default proxy metrics
 */
export function createProxyMetrics(registry: MetricsRegistry): ProxyMetrics {
	return {
		requestsTotal: registry.counter("proxy_requests_total"),
		requestsByStatus: registry.counter("proxy_requests_by_status"),
		requestsByProvider: registry.counter("proxy_requests_by_provider"),
		requestDuration: registry.histogram("proxy_request_duration_ms"),
		activeConnections: registry.counter("proxy_active_connections"),
		tokensUsed: registry.counter("proxy_tokens_used"),
	};
}

/**
 * Global metrics registry singleton
 */
export const globalMetrics = new MetricsRegistry();
