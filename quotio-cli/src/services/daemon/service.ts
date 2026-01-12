import { existsSync, writeFileSync, unlinkSync, readFileSync } from "node:fs";
import { readdir } from "node:fs/promises";
import { ConfigFiles, ensureDir, getCacheDir, getConfigDir } from "../../utils/paths.ts";
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
import type {
  DaemonStatus,
  ProviderQuotaInfo,
  DetectedAgent,
  AuthAccount,
} from "../../ipc/protocol.ts";
import {
  startProxy,
  stopProxy,
  checkHealth,
  getProcessState,
  isProxyRunning,
} from "../proxy-process/index.ts";
import { getQuotaService } from "../quota-service.ts";
import { getAgentDetectionService } from "../agent-detection/service.ts";
import {
  getAgentConfigurationService,
  type ConfigurationMode,
} from "../agent-detection/configuration.ts";
import { CLI_AGENTS, type CLIAgentId } from "../agent-detection/types.ts";
import { PROVIDER_METADATA } from "../../models/provider.ts";

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

interface QuotaCache {
  quotas: ProviderQuotaInfo[];
  lastFetched: Date | null;
}

const quotaCache: QuotaCache = {
  quotas: [],
  lastFetched: null,
};

interface ConfigStore {
  [key: string]: unknown;
}

let configStore: ConfigStore | null = null;

async function loadConfigStore(): Promise<ConfigStore> {
  if (configStore !== null) return configStore;
  
  const configPath = ConfigFiles.config();
  try {
    if (existsSync(configPath)) {
      const content = readFileSync(configPath, "utf-8");
      configStore = JSON.parse(content) as ConfigStore;
    } else {
      configStore = {};
    }
  } catch {
    configStore = {};
  }
  return configStore as ConfigStore;
}

async function saveConfigStore(): Promise<void> {
  if (!configStore) return;
  
  const configPath = ConfigFiles.config();
  await ensureDir(getConfigDir());
  writeFileSync(configPath, JSON.stringify(configStore, null, 2));
}

function getAuthDir(): string {
  const home = process.env.HOME ?? Bun.env.HOME ?? "";
  return `${home}/.cli-proxy-api`;
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

  "quota.fetch": async (params: unknown) => {
    const opts = params as { provider?: string; forceRefresh?: boolean } | undefined;
    const quotaService = getQuotaService();
    
    try {
      const result = await quotaService.fetchAllQuotas();
      const quotas: ProviderQuotaInfo[] = [];
      
      for (const [key, data] of result.quotas) {
        const [provider, email] = key.split(":");
        const providerMeta = Object.values(PROVIDER_METADATA).find(p => p.id === provider);
        
        quotas.push({
          provider: providerMeta?.displayName ?? provider ?? "unknown",
          email: email ?? "unknown",
          models: data.models.map(m => ({
            name: m.name,
            percentage: m.percentage,
            resetTime: m.resetTime,
            used: m.used,
            limit: m.limit,
          })),
          lastUpdated: data.lastUpdated.toISOString(),
          isForbidden: data.isForbidden,
        });
      }
      
      quotaCache.quotas = quotas;
      quotaCache.lastFetched = new Date();
      
      return {
        success: true,
        quotas,
        errors: result.errors.map(e => ({ provider: e.provider, error: e.error })),
      };
    } catch (err) {
      return {
        success: false,
        quotas: [],
        errors: [{ provider: "all", error: err instanceof Error ? err.message : String(err) }],
      };
    }
  },

  "quota.list": async () => ({
    quotas: quotaCache.quotas,
    lastFetched: quotaCache.lastFetched?.toISOString() ?? null,
  }),

  "agent.detect": async (params: unknown) => {
    const opts = params as { forceRefresh?: boolean } | undefined;
    const detectionService = getAgentDetectionService();
    
    const statuses = await detectionService.detectAllAgents(opts?.forceRefresh ?? false);
    const agents: DetectedAgent[] = statuses.map(status => ({
      id: status.agent.id,
      name: status.agent.displayName,
      installed: status.installed,
      configured: status.configured,
      binaryPath: status.binaryPath ?? null,
      version: status.version ?? null,
    }));
    
    return { agents };
  },

  "agent.configure": async (params: unknown) => {
    const opts = params as { agent: string; mode: "auto" | "manual" };
    const agentId = opts.agent as CLIAgentId;
    
    if (!CLI_AGENTS[agentId]) {
      return {
        success: false,
        agent: opts.agent,
        configPath: null,
        backupPath: null,
      };
    }
    
    const configService = getAgentConfigurationService();
    const proxyState = getProcessState();
    const port = proxyState.running ? proxyState.port : 8217;
    
    const result = configService.generateConfiguration(
      agentId,
      {
        agent: CLI_AGENTS[agentId],
        proxyURL: `http://localhost:${port}/v1`,
        apiKey: "quotio-cli-key",
      },
      opts.mode === "auto" ? "automatic" : "manual"
    );
    
    return {
      success: result.success,
      agent: opts.agent,
      configPath: result.configPath ?? null,
      backupPath: result.backupPath ?? null,
    };
  },

  "auth.list": async (params: unknown) => {
    const opts = params as { provider?: string } | undefined;
    const authDir = getAuthDir();
    const accounts: AuthAccount[] = [];
    
    try {
      const files = await readdir(authDir);
      
      for (const fileName of files) {
        if (!fileName.endsWith(".json")) continue;
        if (opts?.provider && !fileName.startsWith(opts.provider)) continue;
        
        const filePath = `${authDir}/${fileName}`;
        try {
          const content = JSON.parse(readFileSync(filePath, "utf-8"));
          const provider = fileName.split("-")[0] ?? "unknown";
          const providerMeta = Object.values(PROVIDER_METADATA).find(
            p => p.id === provider || fileName.startsWith(p.id)
          );
          
          accounts.push({
            id: fileName.replace(".json", ""),
            name: content.email ?? content.account ?? fileName.replace(".json", ""),
            provider: providerMeta?.displayName ?? provider,
            email: content.email,
            status: content.status ?? "ready",
            disabled: Boolean(content.disabled),
          });
        } catch {}
      }
    } catch {}
    
    return { accounts };
  },

  "config.get": async (params: unknown) => {
    const opts = params as { key: string };
    const store = await loadConfigStore();
    return { value: store[opts.key] ?? null };
  },

  "config.set": async (params: unknown) => {
    const opts = params as { key: string; value: unknown };
    const store = await loadConfigStore();
    store[opts.key] = opts.value;
    await saveConfigStore();
    return { success: true as const };
  },
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
