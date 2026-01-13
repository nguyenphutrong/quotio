/**
 * Structured logging utility for quotio-cli.
 * Supports multiple log levels, colored output, and JSON format.
 */

/** Log levels in order of severity */
export enum LogLevel {
	Debug = 0,
	Info = 1,
	Warn = 2,
	Error = 3,
	Silent = 4,
}

/** ANSI color codes for terminal output */
const Colors = {
	reset: "\x1b[0m",
	dim: "\x1b[2m",
	red: "\x1b[31m",
	green: "\x1b[32m",
	yellow: "\x1b[33m",
	blue: "\x1b[34m",
	magenta: "\x1b[35m",
	cyan: "\x1b[36m",
	white: "\x1b[37m",
} as const;

/** Log level display info */
const LevelInfo: Record<LogLevel, { label: string; color: string }> = {
	[LogLevel.Debug]: { label: "DEBUG", color: Colors.dim },
	[LogLevel.Info]: { label: "INFO", color: Colors.blue },
	[LogLevel.Warn]: { label: "WARN", color: Colors.yellow },
	[LogLevel.Error]: { label: "ERROR", color: Colors.red },
	[LogLevel.Silent]: { label: "", color: "" },
};

/** Logger configuration */
export interface LoggerConfig {
	/** Minimum log level to output */
	level: LogLevel;
	/** Output in JSON format instead of human-readable */
	json: boolean;
	/** Include timestamps in output */
	timestamps: boolean;
	/** Use colors in output (auto-detected for TTY) */
	colors: boolean;
}

/** Default logger configuration */
const defaultConfig: LoggerConfig = {
	level: LogLevel.Info,
	json: false,
	timestamps: false,
	colors: process.stdout.isTTY ?? false,
};

/** Current logger configuration */
let config: LoggerConfig = { ...defaultConfig };

/** Configure the logger */
export function configure(options: Partial<LoggerConfig>): void {
	config = { ...config, ...options };
}

/** Get current logger configuration */
export function getConfig(): Readonly<LoggerConfig> {
	return { ...config };
}

/** Reset logger to default configuration */
export function reset(): void {
	config = { ...defaultConfig };
}

/** Parse log level from string */
export function parseLogLevel(level: string): LogLevel {
	const normalized = level.toLowerCase();
	switch (normalized) {
		case "debug":
			return LogLevel.Debug;
		case "info":
			return LogLevel.Info;
		case "warn":
		case "warning":
			return LogLevel.Warn;
		case "error":
			return LogLevel.Error;
		case "silent":
		case "none":
			return LogLevel.Silent;
		default:
			return LogLevel.Info;
	}
}

/** Format a log message */
function formatMessage(
	level: LogLevel,
	message: string,
	data?: Record<string, unknown>,
): string {
	if (config.json) {
		return JSON.stringify({
			level: LevelInfo[level].label.toLowerCase(),
			message,
			...(config.timestamps && { timestamp: new Date().toISOString() }),
			...(data && { data }),
		});
	}

	const parts: string[] = [];
	const levelInfo = LevelInfo[level];

	if (config.timestamps) {
		const time = new Date().toISOString().split("T")[1]?.slice(0, 8) ?? "";
		parts.push(config.colors ? `${Colors.dim}${time}${Colors.reset}` : time);
	}

	if (level !== LogLevel.Silent) {
		const label = levelInfo.label.padEnd(5);
		parts.push(
			config.colors ? `${levelInfo.color}${label}${Colors.reset}` : label,
		);
	}

	parts.push(message);

	if (data && Object.keys(data).length > 0) {
		const dataStr = Object.entries(data)
			.map(([k, v]) => `${k}=${JSON.stringify(v)}`)
			.join(" ");
		parts.push(
			config.colors ? `${Colors.dim}${dataStr}${Colors.reset}` : dataStr,
		);
	}

	return parts.join(" ");
}

/** Log a message at the specified level */
function log(
	level: LogLevel,
	message: string,
	data?: Record<string, unknown>,
): void {
	if (level < config.level) return;

	const formatted = formatMessage(level, message, data);

	if (level === LogLevel.Error) {
		console.error(formatted);
	} else if (level === LogLevel.Warn) {
		console.warn(formatted);
	} else {
		console.log(formatted);
	}
}

/** Logger interface */
export const logger = {
	debug: (message: string, data?: Record<string, unknown>) =>
		log(LogLevel.Debug, message, data),
	info: (message: string, data?: Record<string, unknown>) =>
		log(LogLevel.Info, message, data),
	warn: (message: string, data?: Record<string, unknown>) =>
		log(LogLevel.Warn, message, data),
	error: (message: string, data?: Record<string, unknown>) =>
		log(LogLevel.Error, message, data),

	/** Log without any level prefix (for command output) */
	print: (message: string) => console.log(message),

	/** Log to stderr without level prefix */
	printError: (message: string) => console.error(message),

	/** Configure logger */
	configure,

	/** Get current config */
	getConfig,

	/** Reset to defaults */
	reset,
};

export default logger;
