import { existsSync, writeFileSync, unlinkSync, readFileSync } from "node:fs";
import { ConfigFiles, ensureDir, getCacheDir } from "../../utils/paths.ts";
import { logger } from "../../utils/logger.ts";
import {
  startServer,
  stopServer,
  registerHandlers,
  isServerRunning,
  getSocketPath,
  getConnectionCount,
  type MethodHandler,
} from "../../ipc/server.ts";
import type { DaemonStatus } from "../../ipc/protocol.ts";
import {
  startProxy,
  stopProxy,
  checkHealth,
  getProcessState,
  isProxyRunning,
} from "../proxy-process/index.ts";

interface DaemonState {
  startedAt: Date | null;
  pid: number;
}

const state: DaemonState = {
  startedAt: null,
  pid: process.pid,
};

function getVersion(): string {
  try {
    const pkg = require("../../../package.json");
    return pkg.version ?? "0.0.0";
  } catch {
    return "0.0.0";
  }
}

const handlers: Record<string, MethodHandler> = {
  "daemon.ping": async () => ({
    pong: true as const,
    timestamp: Date.now(),
  }),

  "daemon.status": async (): Promise<DaemonStatus> => {
    const proxyState = getProcessState();
    const uptime = state.startedAt ? Date.now() - state.startedAt.getTime() : 0;

    return {
      running: true,
      pid: state.pid,
      startedAt: state.startedAt?.toISOString() ?? new Date().toISOString(),
      uptime,
      proxyRunning: proxyState.running,
      proxyPort: proxyState.running ? proxyState.port : null,
      version: getVersion(),
    };
  },

  "daemon.shutdown": async (params: unknown) => {
    const opts = params as { graceful?: boolean } | undefined;
    const graceful = opts?.graceful ?? true;

    if (graceful) {
      setTimeout(async () => {
        await shutdown();
        process.exit(0);
      }, 100);
    } else {
      process.exit(0);
    }

    return { success: true as const };
  },

  "proxy.start": async (params: unknown) => {
    const opts = params as { port?: number } | undefined;
    const port = opts?.port ?? 8217;

    await startProxy(port);
    const proxyState = getProcessState();

    return {
      success: true,
      port: proxyState.port,
      pid: proxyState.pid ?? 0,
    };
  },

  "proxy.stop": async () => {
    await stopProxy();
    return { success: true as const };
  },

  "proxy.status": async () => {
    const proxyState = getProcessState();
    const healthy = proxyState.running ? await checkHealth(proxyState.port) : false;

    return {
      running: proxyState.running,
      port: proxyState.running ? proxyState.port : null,
      pid: proxyState.pid,
      startedAt: proxyState.startedAt?.toISOString() ?? null,
      healthy,
    };
  },

  "proxy.health": async () => {
    const proxyState = getProcessState();
    const healthy = proxyState.running ? await checkHealth(proxyState.port) : false;
    return { healthy };
  },

  "quota.fetch": async () => ({
    success: true,
    quotas: [],
    errors: [],
  }),

  "quota.list": async () => ({
    quotas: [],
    lastFetched: null,
  }),

  "agent.detect": async () => ({
    agents: [],
  }),

  "agent.configure": async (params: unknown) => {
    const opts = params as { agent: string; mode: "auto" | "manual" };
    return {
      success: true,
      agent: opts.agent,
      configPath: null,
      backupPath: null,
    };
  },

  "auth.list": async () => ({
    accounts: [],
  }),

  "config.get": async (params: unknown) => {
    const opts = params as { key: string };
    return { value: null };
  },

  "config.set": async () => ({
    success: true as const,
  }),
};

export async function startDaemon(options?: { foreground?: boolean }): Promise<void> {
  const pidPath = ConfigFiles.pidFile();

  if (existsSync(pidPath)) {
    const existingPid = Number.parseInt(readFileSync(pidPath, "utf-8").trim(), 10);
    if (!Number.isNaN(existingPid) && existingPid > 0) {
      try {
        process.kill(existingPid, 0);
        throw new Error(`Daemon already running with PID ${existingPid}`);
      } catch (e) {
        if ((e as NodeJS.ErrnoException).code !== "ESRCH") {
          throw e;
        }
        unlinkSync(pidPath);
      }
    }
  }

  await ensureDir(getCacheDir());
  writeFileSync(pidPath, String(process.pid));

  registerHandlers(handlers);
  await startServer();

  state.startedAt = new Date();
  state.pid = process.pid;

  logger.info(`Daemon started with PID ${process.pid}`);

  if (options?.foreground) {
    setupSignalHandlers();
    await waitForever();
  }
}

export async function stopDaemon(): Promise<void> {
  const pidPath = ConfigFiles.pidFile();

  if (!existsSync(pidPath)) {
    logger.warn("Daemon is not running (no PID file found)");
    return;
  }

  const pid = Number.parseInt(readFileSync(pidPath, "utf-8").trim(), 10);
  if (Number.isNaN(pid) || pid <= 0) {
    unlinkSync(pidPath);
    return;
  }

  try {
    process.kill(pid, "SIGTERM");
    logger.info(`Sent SIGTERM to daemon (PID ${pid})`);

    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) {
      try {
        process.kill(pid, 0);
        await Bun.sleep(100);
      } catch {
        break;
      }
    }

    try {
      process.kill(pid, 0);
      process.kill(pid, "SIGKILL");
      logger.warn("Daemon did not stop gracefully, sent SIGKILL");
    } catch {}
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ESRCH") {
      logger.info("Daemon was not running");
    } else {
      throw e;
    }
  }

  if (existsSync(pidPath)) {
    unlinkSync(pidPath);
  }
}

export async function getDaemonStatus(): Promise<{
  running: boolean;
  pid: number | null;
  socketPath: string;
}> {
  const pidPath = ConfigFiles.pidFile();
  const socketPath = ConfigFiles.socket();

  if (!existsSync(pidPath)) {
    return { running: false, pid: null, socketPath };
  }

  const pid = Number.parseInt(readFileSync(pidPath, "utf-8").trim(), 10);
  if (Number.isNaN(pid) || pid <= 0) {
    return { running: false, pid: null, socketPath };
  }

  try {
    process.kill(pid, 0);
    return { running: true, pid, socketPath };
  } catch {
    return { running: false, pid: null, socketPath };
  }
}

async function shutdown(): Promise<void> {
  logger.info("Shutting down daemon...");

  try {
    await stopProxy();
  } catch {}

  await stopServer();

  const pidPath = ConfigFiles.pidFile();
  if (existsSync(pidPath)) {
    try {
      unlinkSync(pidPath);
    } catch {}
  }

  logger.info("Daemon stopped");
}

function setupSignalHandlers(): void {
  const handleSignal = async (signal: string) => {
    logger.info(`Received ${signal}, shutting down...`);
    await shutdown();
    process.exit(0);
  };

  process.on("SIGINT", () => handleSignal("SIGINT"));
  process.on("SIGTERM", () => handleSignal("SIGTERM"));
}

function waitForever(): Promise<never> {
  return new Promise(() => {});
}

export { isServerRunning, getSocketPath, getConnectionCount };
