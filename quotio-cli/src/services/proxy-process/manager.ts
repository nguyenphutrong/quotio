import type { Subprocess } from "bun";
import {
	getProxyBinaryPath,
	getProxyConfigPath,
	getProxyPidPath,
} from "../proxy-binary/constants.ts";
import { ensureConfigExists } from "./config.ts";

export interface ProxyProcessState {
	running: boolean;
	pid: number | null;
	port: number;
	startedAt: Date | null;
}

let currentProcess: Subprocess | null = null;
let processState: ProxyProcessState = {
	running: false,
	pid: null,
	port: 8217,
	startedAt: null,
};

export function getProcessState(): ProxyProcessState {
	return { ...processState };
}

export async function startProxy(port = 8217): Promise<void> {
	if (processState.running) {
		throw new Error("Proxy is already running");
	}

	const binaryPath = getProxyBinaryPath();
	const binaryFile = Bun.file(binaryPath);
	if (!(await binaryFile.exists())) {
		throw new Error(
			`Proxy binary not found at ${binaryPath}. Run 'quotio proxy install' first.`,
		);
	}

	await cleanupOrphanProcesses(port);
	const configPath = await ensureConfigExists(port);

	currentProcess = Bun.spawn([binaryPath, "-config", configPath], {
		cwd: new URL(".", `file://${binaryPath}`).pathname,
		stdout: "pipe",
		stderr: "pipe",
		env: { ...process.env, TERM: "xterm-256color" },
	});

	if (currentProcess.stdout && typeof currentProcess.stdout !== "number") {
		drainPipeAsync(currentProcess.stdout);
	}
	if (currentProcess.stderr && typeof currentProcess.stderr !== "number") {
		drainPipeAsync(currentProcess.stderr);
	}

	const pid = currentProcess.pid;
	await writePidFile(pid);

	processState = {
		running: true,
		pid,
		port,
		startedAt: new Date(),
	};

	await Bun.sleep(1500);

	if (currentProcess.exitCode !== null) {
		processState.running = false;
		processState.pid = null;
		throw new Error(
			`Proxy failed to start (exit code: ${currentProcess.exitCode})`,
		);
	}

	const healthy = await checkHealth(port);
	if (!healthy) {
		await stopProxy();
		throw new Error("Proxy started but health check failed");
	}

	setupProcessWatcher();
}

export async function stopProxy(): Promise<void> {
	if (!processState.running || !currentProcess) {
		processState.running = false;
		processState.pid = null;
		await removePidFile();
		return;
	}

	const pid = processState.pid;
	const port = processState.port;

	currentProcess.kill("SIGTERM");

	const deadline = Date.now() + 2000;
	while (currentProcess.exitCode === null && Date.now() < deadline) {
		await Bun.sleep(100);
	}

	if (currentProcess.exitCode === null && pid) {
		process.kill(pid, "SIGKILL");
	}

	currentProcess = null;
	processState = {
		running: false,
		pid: null,
		port,
		startedAt: null,
	};

	await killProcessOnPort(port);
	await removePidFile();
}

export async function restartProxy(port?: number): Promise<void> {
	const currentPort = port ?? processState.port;
	await stopProxy();
	await Bun.sleep(500);
	await startProxy(currentPort);
}

export async function checkHealth(port = 8217): Promise<boolean> {
	try {
		const controller = new AbortController();
		const timeoutId = setTimeout(() => controller.abort(), 5000);

		const response = await fetch(`http://localhost:${port}/health`, {
			signal: controller.signal,
			headers: { Connection: "close" },
		});

		clearTimeout(timeoutId);
		return response.ok;
	} catch {
		return false;
	}
}

function drainPipeAsync(stream: ReadableStream<Uint8Array> | null): void {
	if (!stream) return;
	const reader = stream.getReader();
	(async () => {
		try {
			while (true) {
				const { done } = await reader.read();
				if (done) break;
			}
		} catch {}
	})();
}

function setupProcessWatcher(): void {
	if (!currentProcess) return;

	currentProcess.exited.then((exitCode) => {
		processState.running = false;
		processState.pid = null;
		currentProcess = null;

		if (exitCode !== 0) {
			console.error(`[quotio] Proxy exited with code ${exitCode}`);
		}
	});
}

async function cleanupOrphanProcesses(port: number): Promise<void> {
	const pidPath = getProxyPidPath();
	const pidFile = Bun.file(pidPath);

	if (await pidFile.exists()) {
		try {
			const content = await pidFile.text();
			const oldPid = Number.parseInt(content.trim(), 10);
			if (!Number.isNaN(oldPid) && oldPid > 0) {
				try {
					process.kill(oldPid, "SIGTERM");
					await Bun.sleep(500);
					process.kill(oldPid, "SIGKILL");
				} catch {}
			}
		} catch {}
	}

	await killProcessOnPort(port);
}

async function killProcessOnPort(port: number): Promise<void> {
	try {
		const lsof = Bun.spawn(["lsof", "-ti", `tcp:${port}`], {
			stdout: "pipe",
			stderr: "pipe",
		});
		const output = await new Response(lsof.stdout).text();
		const pids = output.trim().split("\n").filter(Boolean);

		for (const pid of pids) {
			const pidNum = Number.parseInt(pid, 10);
			if (!Number.isNaN(pidNum) && pidNum > 0) {
				try {
					process.kill(pidNum, "SIGKILL");
				} catch {}
			}
		}
	} catch {}
}

async function writePidFile(pid: number): Promise<void> {
	const pidPath = getProxyPidPath();
	await Bun.write(pidPath, String(pid));
}

async function removePidFile(): Promise<void> {
	const pidPath = getProxyPidPath();
	await Bun.spawn(["rm", "-f", pidPath]).exited;
}

export async function getProxyPid(): Promise<number | null> {
	const pidPath = getProxyPidPath();
	const pidFile = Bun.file(pidPath);

	if (!(await pidFile.exists())) {
		return null;
	}

	try {
		const content = await pidFile.text();
		const pid = Number.parseInt(content.trim(), 10);
		return Number.isNaN(pid) ? null : pid;
	} catch {
		return null;
	}
}

export async function isProxyRunning(): Promise<boolean> {
	const pid = await getProxyPid();
	if (!pid) return false;

	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}
