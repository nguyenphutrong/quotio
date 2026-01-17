/**
 * Request logging utilities
 * @packageDocumentation
 */

import type { Context, MiddlewareHandler } from "hono";

/**
 * Log levels
 */
export type LogLevel = "debug" | "info" | "warn" | "error";

/**
 * Log entry for a request
 */
export interface RequestLogEntry {
	/** Request ID */
	requestId: string;
	/** Timestamp in ISO format */
	timestamp: string;
	/** HTTP method */
	method: string;
	/** Request path */
	path: string;
	/** Query parameters */
	query?: Record<string, string>;
	/** Response status */
	status?: number;
	/** Duration in milliseconds */
	durationMs?: number;
	/** Provider used */
	provider?: string;
	/** Model used */
	model?: string;
	/** Error message if failed */
	error?: string;
	/** Additional metadata */
	metadata?: Record<string, unknown>;
}

/**
 * Logger configuration
 */
export interface LoggerConfig {
	/** Minimum log level */
	level: LogLevel;
	/** Whether to include query params */
	includeQuery: boolean;
	/** Whether to include metadata */
	includeMetadata: boolean;
	/** Paths to skip logging */
	skipPaths: string[];
	/** Custom log handler */
	handler?: (entry: RequestLogEntry, level: LogLevel) => void;
}

/**
 * Default configuration
 */
const DEFAULT_CONFIG: LoggerConfig = {
	level: "info",
	includeQuery: true,
	includeMetadata: true,
	skipPaths: ["/health", "/healthz", "/ready"],
};

/**
 * Log level priority
 */
const LEVEL_PRIORITY: Record<LogLevel, number> = {
	debug: 0,
	info: 1,
	warn: 2,
	error: 3,
};

/**
 * Generate a unique request ID
 */
function generateRequestId(): string {
	const bytes = new Uint8Array(8);
	crypto.getRandomValues(bytes);
	return Array.from(bytes)
		.map((b) => b.toString(16).padStart(2, "0"))
		.join("");
}

/**
 * Request logger class
 */
export class RequestLogger {
	private config: LoggerConfig;
	private logs: RequestLogEntry[] = [];
	private maxLogs = 1000;

	constructor(config: Partial<LoggerConfig> = {}) {
		this.config = { ...DEFAULT_CONFIG, ...config };
	}

	/**
	 * Check if should log at level
	 */
	private shouldLog(level: LogLevel): boolean {
		return LEVEL_PRIORITY[level] >= LEVEL_PRIORITY[this.config.level];
	}

	/**
	 * Log an entry
	 */
	log(entry: RequestLogEntry, level: LogLevel = "info"): void {
		if (!this.shouldLog(level)) return;

		// Store in memory
		this.logs.push(entry);
		if (this.logs.length > this.maxLogs) {
			this.logs.shift();
		}

		// Call custom handler or default console
		if (this.config.handler) {
			this.config.handler(entry, level);
		} else {
			this.defaultHandler(entry, level);
		}
	}

	/**
	 * Default console handler
	 */
	private defaultHandler(entry: RequestLogEntry, level: LogLevel): void {
		const prefix = `[${entry.timestamp}] [${level.toUpperCase()}]`;
		const basic = `${entry.method} ${entry.path}`;

		let message = `${prefix} ${basic}`;

		if (entry.status !== undefined) {
			message += ` ${entry.status}`;
		}

		if (entry.durationMs !== undefined) {
			message += ` ${entry.durationMs}ms`;
		}

		if (entry.provider) {
			message += ` [${entry.provider}]`;
		}

		if (entry.model) {
			message += ` [${entry.model}]`;
		}

		if (entry.error) {
			message += ` ERROR: ${entry.error}`;
		}

		switch (level) {
			case "debug":
				console.debug(message);
				break;
			case "info":
				console.info(message);
				break;
			case "warn":
				console.warn(message);
				break;
			case "error":
				console.error(message);
				break;
		}
	}

	/**
	 * Get recent logs
	 */
	getRecentLogs(count = 100): RequestLogEntry[] {
		return this.logs.slice(-count);
	}

	/**
	 * Clear logs
	 */
	clearLogs(): void {
		this.logs = [];
	}

	/**
	 * Create Hono middleware
	 */
	middleware(): MiddlewareHandler {
		return async (c: Context, next) => {
			// Skip paths
			if (this.config.skipPaths.some((p) => c.req.path.startsWith(p))) {
				return next();
			}

			const requestId = generateRequestId();
			const startTime = performance.now();

			// Set request ID in context
			c.set("requestId", requestId);

			// Build base entry
			const entry: RequestLogEntry = {
				requestId,
				timestamp: new Date().toISOString(),
				method: c.req.method,
				path: c.req.path,
			};

			if (this.config.includeQuery) {
				const query = c.req.query();
				if (Object.keys(query).length > 0) {
					entry.query = query;
				}
			}

			try {
				await next();

				// Add response info
				entry.status = c.res.status;
				entry.durationMs = Math.round(performance.now() - startTime);

				// Get provider/model from context if available
				const provider = c.get("provider") as string | undefined;
				const model = c.get("model") as string | undefined;
				if (provider) entry.provider = provider;
				if (model) entry.model = model;

				// Get metadata if enabled
				if (this.config.includeMetadata) {
					const metadata = c.get("logMetadata") as
						| Record<string, unknown>
						| undefined;
					if (metadata) entry.metadata = metadata;
				}

				const level = entry.status >= 500 ? "error" : entry.status >= 400 ? "warn" : "info";
				this.log(entry, level);
			} catch (error) {
				entry.durationMs = Math.round(performance.now() - startTime);
				entry.error =
					error instanceof Error ? error.message : String(error);
				entry.status = 500;
				this.log(entry, "error");
				throw error;
			}
		};
	}
}

/**
 * Get request ID from context
 */
export function getRequestId(c: Context): string | undefined {
	return c.get("requestId") as string | undefined;
}

/**
 * Add metadata to log entry
 */
export function addLogMetadata(
	c: Context,
	metadata: Record<string, unknown>
): void {
	const existing = (c.get("logMetadata") as Record<string, unknown>) || {};
	c.set("logMetadata", { ...existing, ...metadata });
}
