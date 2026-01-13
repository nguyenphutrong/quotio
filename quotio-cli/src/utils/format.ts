/**
 * Output formatting utilities for CLI.
 * Supports table, JSON, and plain text formats.
 */

/** Output format types */
export type OutputFormat = "table" | "json" | "plain";

/** ANSI color codes */
const Colors = {
	reset: "\x1b[0m",
	bold: "\x1b[1m",
	dim: "\x1b[2m",
	red: "\x1b[31m",
	green: "\x1b[32m",
	yellow: "\x1b[33m",
	blue: "\x1b[34m",
	cyan: "\x1b[36m",
} as const;

/** Check if output supports colors */
const supportsColor = process.stdout.isTTY ?? false;

/**
 * Regex to strip ANSI escape codes from text.
 * Uses ESC (0x1b) followed by CSI sequences.
 */
// biome-ignore lint/suspicious/noControlCharactersInRegex: Required for ANSI escape sequence stripping
const ANSI_STRIP_REGEX = /\x1b\[[0-9;]*m/g;

/** Strip ANSI codes from text to get visible length */
function stripAnsi(text: string): string {
	return text.replace(ANSI_STRIP_REGEX, "");
}

/** Apply color if supported */
function color(text: string, colorCode: string): string {
	return supportsColor ? `${colorCode}${text}${Colors.reset}` : text;
}

/** Color helper functions */
export const colors = {
	bold: (text: string) => color(text, Colors.bold),
	dim: (text: string) => color(text, Colors.dim),
	red: (text: string) => color(text, Colors.red),
	green: (text: string) => color(text, Colors.green),
	yellow: (text: string) => color(text, Colors.yellow),
	blue: (text: string) => color(text, Colors.blue),
	cyan: (text: string) => color(text, Colors.cyan),
	success: (text: string) => color(text, Colors.green),
	error: (text: string) => color(text, Colors.red),
	warning: (text: string) => color(text, Colors.yellow),
	info: (text: string) => color(text, Colors.blue),
};

/** Table column definition */
export interface TableColumn {
	key: string;
	header: string;
	width?: number;
	align?: "left" | "right" | "center";
	format?: (value: unknown) => string;
}

/** Format data as a table */
export function formatTable<T extends Record<string, unknown>>(
	data: T[],
	columns: TableColumn[],
): string {
	if (data.length === 0) {
		return colors.dim("No data");
	}

	// Calculate column widths
	const widths = columns.map((col) => {
		const headerWidth = col.header.length;
		const maxDataWidth = Math.max(
			...data.map((row) => {
				const value = row[col.key];
				const formatted = col.format ? col.format(value) : String(value ?? "");
				return stripAnsi(formatted).length;
			}),
		);
		return col.width ?? Math.max(headerWidth, maxDataWidth);
	});

	const header = columns
		.map((col, i) => alignText(col.header, widths[i] ?? 0, col.align ?? "left"))
		.join("  ");

	// Format separator
	const separator = widths.map((w) => "─".repeat(w)).join("──");

	// Format rows
	const rows = data.map((row) =>
		columns
			.map((col, i) => {
				const value = row[col.key];
				const formatted = col.format ? col.format(value) : String(value ?? "");
				return alignText(formatted, widths[i] ?? 0, col.align ?? "left");
			})
			.join("  "),
	);

	return [colors.bold(header), colors.dim(separator), ...rows].join("\n");
}

/** Align text within a given width */
function alignText(
	text: string,
	width: number,
	align: "left" | "right" | "center",
): string {
	const visibleLength = stripAnsi(text).length;
	const padding = Math.max(0, width - visibleLength);

	switch (align) {
		case "right":
			return " ".repeat(padding) + text;
		case "center": {
			const left = Math.floor(padding / 2);
			const right = padding - left;
			return " ".repeat(left) + text + " ".repeat(right);
		}
		default:
			return text + " ".repeat(padding);
	}
}

/** Format data as JSON */
export function formatJson(data: unknown, pretty = true): string {
	return pretty ? JSON.stringify(data, null, 2) : JSON.stringify(data);
}

/** Format data as plain key-value pairs */
export function formatPlain<T extends Record<string, unknown>>(
	data: T,
	keys?: string[],
): string {
	const entries = keys
		? keys.map((k) => [k, data[k]] as const)
		: Object.entries(data);

	return entries
		.filter(([, v]) => v !== undefined && v !== null)
		.map(([k, v]) => `${k}: ${v}`)
		.join("\n");
}

/** Format a list as bullet points */
export function formatList(items: string[], bullet = "•"): string {
	return items.map((item) => `${bullet} ${item}`).join("\n");
}

/** Format bytes to human readable string */
export function formatBytes(bytes: number): string {
	if (bytes === 0) return "0 B";
	const k = 1024;
	const sizes = ["B", "KB", "MB", "GB", "TB"];
	const i = Math.floor(Math.log(bytes) / Math.log(k));
	return `${(bytes / k ** i).toFixed(1)} ${sizes[i]}`;
}

/** Format number with thousand separators */
export function formatNumber(num: number): string {
	return num.toLocaleString("en-US");
}

/** Format currency (USD by default) */
export function formatCurrency(amount: number, currency = "USD"): string {
	return new Intl.NumberFormat("en-US", {
		style: "currency",
		currency,
	}).format(amount);
}

/** Format percentage */
export function formatPercent(value: number, decimals = 1): string {
	return `${(value * 100).toFixed(decimals)}%`;
}

/** Format duration in milliseconds to human readable */
export function formatDuration(ms: number): string {
	if (ms < 1000) return `${ms}ms`;
	if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
	if (ms < 3600000)
		return `${Math.floor(ms / 60000)}m ${Math.floor((ms % 60000) / 1000)}s`;
	return `${Math.floor(ms / 3600000)}h ${Math.floor((ms % 3600000) / 60000)}m`;
}

/** Format date to human readable */
export function formatDate(
	date: Date | string | number,
	style: "short" | "long" = "short",
): string {
	const d = new Date(date);
	if (style === "long") {
		return d.toLocaleString("en-US", {
			year: "numeric",
			month: "long",
			day: "numeric",
			hour: "2-digit",
			minute: "2-digit",
		});
	}
	return d.toLocaleString("en-US", {
		month: "short",
		day: "numeric",
		hour: "2-digit",
		minute: "2-digit",
	});
}

/** Format relative time (e.g., "2 hours ago") */
export function formatRelativeTime(date: Date | string | number): string {
	const d = new Date(date);
	const now = new Date();
	const diffMs = now.getTime() - d.getTime();
	const diffSec = Math.floor(diffMs / 1000);
	const diffMin = Math.floor(diffSec / 60);
	const diffHour = Math.floor(diffMin / 60);
	const diffDay = Math.floor(diffHour / 24);

	if (diffSec < 60) return "just now";
	if (diffMin < 60) return `${diffMin}m ago`;
	if (diffHour < 24) return `${diffHour}h ago`;
	if (diffDay < 7) return `${diffDay}d ago`;
	return formatDate(d, "short");
}

/** Status indicator with color */
export function formatStatus(
	status: "ok" | "error" | "warning" | "pending" | "unknown",
): string {
	switch (status) {
		case "ok":
			return colors.green("●");
		case "error":
			return colors.red("●");
		case "warning":
			return colors.yellow("●");
		case "pending":
			return colors.blue("○");
		default:
			return colors.dim("○");
	}
}

/** Format output based on format type */
export function formatOutput<T>(
	data: T,
	format: OutputFormat,
	tableColumns?: TableColumn[],
): string {
	switch (format) {
		case "json":
			return formatJson(data);
		case "plain":
			if (Array.isArray(data)) {
				return data
					.map((item) => formatPlain(item as Record<string, unknown>))
					.join("\n\n");
			}
			return formatPlain(data as Record<string, unknown>);
		default:
			if (Array.isArray(data) && tableColumns) {
				return formatTable(data as Record<string, unknown>[], tableColumns);
			}
			return formatJson(data);
	}
}

/** Create a progress bar */
export function formatProgressBar(
	current: number,
	total: number,
	width = 20,
): string {
	const percent = Math.min(1, current / total);
	const filled = Math.round(width * percent);
	const empty = width - filled;
	const bar = "█".repeat(filled) + "░".repeat(empty);
	return `[${bar}] ${formatPercent(percent, 0)}`;
}

/** Create a box around text */
export function formatBox(title: string, content: string): string {
	const lines = content.split("\n");
	const maxWidth = Math.max(title.length, ...lines.map((l) => l.length));
	const top = `┌─ ${title} ${"─".repeat(Math.max(0, maxWidth - title.length))}┐`;
	const bottom = `└${"─".repeat(maxWidth + 2)}┘`;
	const middle = lines.map((line) => `│ ${line.padEnd(maxWidth)} │`).join("\n");
	return [top, middle, bottom].join("\n");
}
