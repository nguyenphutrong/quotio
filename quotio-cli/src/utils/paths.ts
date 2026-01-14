/**
 * Platform-specific paths for quotio-cli configuration and data storage.
 * Follows XDG Base Directory Specification on Linux, standard paths on macOS/Windows.
 */

import { homedir } from "node:os";
import { join } from "node:path";

/** Detected operating system */
export type Platform = "darwin" | "linux" | "win32";

/** Get current platform */
export function getPlatform(): Platform {
	const platform = process.platform;
	if (platform === "darwin" || platform === "linux" || platform === "win32") {
		return platform;
	}
	// Default to linux for other Unix-like systems
	return "linux";
}

/**
 * Get the configuration directory for quotio-cli.
 * Uses ~/.config/quotio for all platforms (XDG-compliant).
 */
export function getConfigDir(): string {
	const home = homedir();
	return join(home, ".config", "quotio");
}

/**
 * Get the data directory for quotio-cli (logs, cache, etc.).
 * - macOS: ~/Library/Application Support/quotio-cli
 * - Linux: ~/.local/share/quotio-cli (XDG_DATA_HOME)
 * - Windows: %LOCALAPPDATA%/quotio-cli
 */
export function getDataDir(): string {
	const platform = getPlatform();
	const home = homedir();

	switch (platform) {
		case "darwin":
			return join(home, "Library", "Application Support", "quotio-cli");
		case "win32":
			return join(
				process.env.LOCALAPPDATA || join(home, "AppData", "Local"),
				"quotio-cli",
			);
		default:
			return join(
				process.env.XDG_DATA_HOME || join(home, ".local", "share"),
				"quotio-cli",
			);
	}
}

/**
 * Get the cache directory for quotio-cli.
 * - macOS: ~/Library/Caches/quotio-cli
 * - Linux: ~/.cache/quotio-cli (XDG_CACHE_HOME)
 * - Windows: %LOCALAPPDATA%/quotio-cli/cache
 */
export function getCacheDir(): string {
	const platform = getPlatform();
	const home = homedir();

	switch (platform) {
		case "darwin":
			return join(home, "Library", "Caches", "quotio-cli");
		case "win32":
			return join(
				process.env.LOCALAPPDATA || join(home, "AppData", "Local"),
				"quotio-cli",
				"cache",
			);
		default:
			return join(
				process.env.XDG_CACHE_HOME || join(home, ".cache"),
				"quotio-cli",
			);
	}
}

/**
 * Get the logs directory for quotio-cli.
 * - macOS: ~/Library/Logs/quotio-cli
 * - Linux: ~/.local/share/quotio-cli/logs
 * - Windows: %LOCALAPPDATA%/quotio-cli/logs
 */
export function getLogsDir(): string {
	const platform = getPlatform();
	const home = homedir();

	switch (platform) {
		case "darwin":
			return join(home, "Library", "Logs", "quotio-cli");
		case "win32":
			return join(
				process.env.LOCALAPPDATA || join(home, "AppData", "Local"),
				"quotio-cli",
				"logs",
			);
		default:
			return join(getDataDir(), "logs");
	}
}

/** TCP port for Windows IPC (since Bun doesn't support named pipes on Windows yet) */
export const WINDOWS_IPC_PORT = 18217;
export const WINDOWS_IPC_HOST = "127.0.0.1";

/** IPC connection info - either Unix socket path or TCP address */
export type IPCConnectionInfo =
	| { type: "unix"; path: string }
	| { type: "tcp"; host: string; port: number };

/** Standard file paths within the config directory */
export const ConfigFiles = {
	/** Main configuration file */
	config: () => join(getConfigDir(), "config.json"),
	/** Credentials/auth tokens */
	credentials: () => join(getConfigDir(), "credentials.json"),
	/** CLI state (last used settings, etc.) */
	state: () => join(getDataDir(), "state.json"),
	/**
	 * Daemon socket path (for Unix) or display string (for Windows).
	 * Use getIPCConnectionInfo() for actual connection parameters.
	 * @deprecated Use getIPCConnectionInfo() for connection logic
	 */
	socket: () => {
		const platform = getPlatform();
		if (platform === "win32") {
			return `${WINDOWS_IPC_HOST}:${WINDOWS_IPC_PORT}`;
		}
		return join(getCacheDir(), "quotio.sock");
	},
	/** PID file for daemon */
	pidFile: () => join(getCacheDir(), "quotio.pid"),
} as const;

/**
 * Get IPC connection info for the current platform.
 * - macOS/Linux: Unix socket
 * - Windows: TCP socket (fallback since Bun doesn't support named pipes)
 */
export function getIPCConnectionInfo(): IPCConnectionInfo {
	const platform = getPlatform();
	if (platform === "win32") {
		return { type: "tcp", host: WINDOWS_IPC_HOST, port: WINDOWS_IPC_PORT };
	}
	return { type: "unix", path: join(getCacheDir(), "quotio.sock") };
}

/**
 * Ensure a directory exists, creating it if necessary.
 */
export async function ensureDir(dir: string): Promise<void> {
	const fs = await import("node:fs/promises");
	await fs.mkdir(dir, { recursive: true });
}

/**
 * Ensure all quotio-cli directories exist.
 */
export async function ensureAllDirs(): Promise<void> {
	await Promise.all([
		ensureDir(getConfigDir()),
		ensureDir(getDataDir()),
		ensureDir(getCacheDir()),
		ensureDir(getLogsDir()),
	]);
}

/**
 * Get CLIProxyAPI default paths (where the Swift app stores data).
 * Used for migration and compatibility.
 */
export const CLIProxyPaths = {
	/** Default CLIProxyAPI base URL */
	defaultBaseURL: "http://localhost:8217",
	/** macOS app support directory for CLIProxyAPI */
	macOSAppSupport: () =>
		join(homedir(), "Library", "Application Support", "CLIProxyAPI"),
	/** Auth files location */
	authFiles: () =>
		join(homedir(), "Library", "Application Support", "CLIProxyAPI", "auth"),
} as const;
