import { type ChildProcess, spawn } from "node:child_process";
import { execSync } from "node:child_process";
import { existsSync } from "node:fs";

export type TunnelStatus =
	| "idle"
	| "starting"
	| "active"
	| "stopping"
	| "error";

export interface TunnelState {
	status: TunnelStatus;
	publicURL: string | null;
	errorMessage: string | null;
	startTime: string | null;
}

export interface CloudflaredInstallation {
	isInstalled: boolean;
	path: string | null;
	version: string | null;
}

const TUNNEL_URL_PATTERN = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/;

function getBinaryPaths(): string[] {
	if (process.platform === "win32") {
		return [
			"C:\\Program Files\\cloudflared\\cloudflared.exe",
			"C:\\Program Files (x86)\\cloudflared\\cloudflared.exe",
			`${process.env.LOCALAPPDATA}\\cloudflared\\cloudflared.exe`,
		];
	}
	if (process.platform === "darwin") {
		return [
			"/opt/homebrew/bin/cloudflared",
			"/usr/local/bin/cloudflared",
			"/usr/bin/cloudflared",
		];
	}
	return [
		"/usr/local/bin/cloudflared",
		"/usr/bin/cloudflared",
		"/snap/bin/cloudflared",
	];
}

function detectInstallation(): CloudflaredInstallation {
	for (const path of getBinaryPaths()) {
		if (existsSync(path)) {
			const version = getVersion(path);
			return { isInstalled: true, path, version };
		}
	}
	return { isInstalled: false, path: null, version: null };
}

function getVersion(binaryPath: string): string | null {
	try {
		const output = execSync(`"${binaryPath}" --version`, {
			encoding: "utf-8",
			timeout: 5000,
		});
		const match = output.match(/\d+\.\d+\.\d+/);
		return match ? match[0] : null;
	} catch {
		return null;
	}
}

class CloudflaredService {
	private process: ChildProcess | null = null;
	private state: TunnelState = {
		status: "idle",
		publicURL: null,
		errorMessage: null,
		startTime: null,
	};
	private outputBuffer = "";
	private urlDetected = false;
	private startTimeoutHandle: ReturnType<typeof setTimeout> | null = null;

	getState(): TunnelState {
		return { ...this.state };
	}

	getInstallation(): CloudflaredInstallation {
		return detectInstallation();
	}

	async start(port: number): Promise<{ success: boolean; error?: string }> {
		if (this.process) {
			return { success: false, error: "Tunnel is already running" };
		}

		const installation = detectInstallation();
		if (!installation.isInstalled || !installation.path) {
			this.state = {
				status: "error",
				publicURL: null,
				errorMessage: "Cloudflared is not installed",
				startTime: null,
			};
			return { success: false, error: "Cloudflared is not installed" };
		}

		const binaryPath = installation.path;
		this.state = {
			status: "starting",
			publicURL: null,
			errorMessage: null,
			startTime: null,
		};
		this.outputBuffer = "";
		this.urlDetected = false;

		return new Promise((resolve) => {
			const args = [
				"tunnel",
				"--config",
				process.platform === "win32" ? "NUL" : "/dev/null",
				"--url",
				`http://localhost:${port}`,
			];

			try {
				this.process = spawn(binaryPath, args, {
					stdio: ["ignore", "pipe", "pipe"],
				});
			} catch (err) {
				const error = err instanceof Error ? err.message : String(err);
				this.state = {
					status: "error",
					publicURL: null,
					errorMessage: error,
					startTime: null,
				};
				this.cleanup();
				resolve({ success: false, error });
				return;
			}

			this.startTimeoutHandle = setTimeout(() => {
				if (this.state.status === "starting") {
					this.state = {
						status: "error",
						publicURL: null,
						errorMessage: "Tunnel start timed out",
						startTime: null,
					};
					this.stop();
				}
			}, 30000);

			const handleOutput = (data: Buffer) => {
				if (this.urlDetected) return;
				this.outputBuffer += data.toString("utf-8");
				if (this.outputBuffer.length > 65536) {
					this.outputBuffer = this.outputBuffer.slice(-65536);
				}
				const match = this.outputBuffer.match(TUNNEL_URL_PATTERN);
				if (match) {
					this.urlDetected = true;
					this.state = {
						status: "active",
						publicURL: match[0],
						errorMessage: null,
						startTime: new Date().toISOString(),
					};
					this.clearStartTimeout();
				}
			};

			this.process.stdout?.on("data", handleOutput);
			this.process.stderr?.on("data", handleOutput);

			this.process.on("error", (err) => {
				this.state = {
					status: "error",
					publicURL: null,
					errorMessage: err.message,
					startTime: null,
				};
				this.cleanup();
			});

			this.process.on("exit", (code) => {
				if (
					this.state.status === "active" ||
					this.state.status === "starting"
				) {
					this.state = {
						status: "error",
						publicURL: null,
						errorMessage: `Tunnel exited unexpectedly (code: ${code})`,
						startTime: null,
					};
				}
				this.cleanup();
			});

			setTimeout(() => {
				if (this.process && !this.process.killed) {
					resolve({ success: true });
				}
			}, 500);
		});
	}

	async stop(): Promise<void> {
		this.clearStartTimeout();
		if (!this.process) {
			this.state = {
				status: "idle",
				publicURL: null,
				errorMessage: null,
				startTime: null,
			};
			return;
		}

		this.state = { ...this.state, status: "stopping" };

		const proc = this.process;
		proc.kill("SIGTERM");

		await new Promise<void>((resolve) => {
			const timeout = setTimeout(() => {
				if (!proc.killed) {
					proc.kill("SIGKILL");
				}
				resolve();
			}, 500);

			proc.once("exit", () => {
				clearTimeout(timeout);
				resolve();
			});
		});

		this.cleanup();
		this.state = {
			status: "idle",
			publicURL: null,
			errorMessage: null,
			startTime: null,
		};
	}

	isRunning(): boolean {
		return this.process !== null && !this.process.killed;
	}

	private cleanup(): void {
		this.clearStartTimeout();
		if (this.process) {
			this.process.stdout?.removeAllListeners();
			this.process.stderr?.removeAllListeners();
			this.process.removeAllListeners();
			this.process = null;
		}
		this.outputBuffer = "";
	}

	private clearStartTimeout(): void {
		if (this.startTimeoutHandle) {
			clearTimeout(this.startTimeoutHandle);
			this.startTimeoutHandle = null;
		}
	}
}

let serviceInstance: CloudflaredService | null = null;

export function getCloudflaredService(): CloudflaredService {
	if (!serviceInstance) {
		serviceInstance = new CloudflaredService();
	}
	return serviceInstance;
}
