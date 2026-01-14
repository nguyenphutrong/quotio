import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { readdir } from "node:fs/promises";
import type {
	AuthAccount,
	DaemonStatus,
	DetectedAgent,
	FallbackEntryInfo,
	ProviderQuotaInfo,
	VirtualModelInfo,
} from "../../ipc/protocol.ts";
import type { UniversalProviderInfo } from "../../ipc/protocol.ts";
import {
	type MethodHandler,
	getConnectionCount,
	getConnectionInfo,
	isServerRunning,
	registerHandlers,
	startServer,
	stopServer,
} from "../../ipc/server.ts";
import { PROVIDER_METADATA } from "../../models/provider.ts";
import { createRequestLog } from "../../models/request-log.ts";
import type { UniversalProvider } from "../../models/universal-provider.ts";
import { logger } from "../../utils/logger.ts";
import {
	ConfigFiles,
	ensureDir,
	getCacheDir,
	getConfigDir,
} from "../../utils/paths.ts";
import {
	type ConfigurationMode,
	getAgentConfigurationService,
} from "../agent-detection/configuration.ts";
import { getAgentDetectionService } from "../agent-detection/service.ts";
import { type CLIAgentId, CLI_AGENTS } from "../agent-detection/types.ts";
import {
	checkHealth,
	getProcessState,
	isProxyRunning,
	startProxy,
	stopProxy,
} from "../proxy-process/index.ts";
import { getQuotaService } from "../quota-service.ts";
import { requestTrackerService } from "./request-tracker-service.ts";

function toProviderInfo(p: UniversalProvider): UniversalProviderInfo {
	return {
		id: p.id,
		name: p.name,
		baseURL: p.baseURL,
		modelId: p.modelId,
		isBuiltIn: p.isBuiltIn,
		iconAssetName: p.iconAssetName ?? null,
		color: p.color,
		supportedAgents: p.supportedAgents,
		isEnabled: p.isEnabled,
		createdAt: p.createdAt,
		updatedAt: p.updatedAt,
	};
}

function toVirtualModelInfo(vm: {
	id: string;
	name: string;
	fallbackEntries: Array<{
		id: string;
		provider: string;
		modelId: string;
		priority: number;
	}>;
	isEnabled: boolean;
}): VirtualModelInfo {
	return {
		id: vm.id,
		name: vm.name,
		fallbackEntries: vm.fallbackEntries.map(toFallbackEntryInfo),
		isEnabled: vm.isEnabled,
	};
}

function toFallbackEntryInfo(entry: {
	id: string;
	provider: string;
	modelId: string;
	priority: number;
}): FallbackEntryInfo {
	return {
		id: entry.id,
		provider: entry.provider,
		modelId: entry.modelId,
		priority: entry.priority,
	};
}

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
		const healthy = proxyState.running
			? await checkHealth(proxyState.port)
			: false;

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
		const healthy = proxyState.running
			? await checkHealth(proxyState.port)
			: false;
		return { healthy };
	},

	"quota.fetch": async (params: unknown) => {
		const opts = params as
			| { provider?: string; forceRefresh?: boolean }
			| undefined;
		const quotaService = getQuotaService();

		try {
			const result = await quotaService.fetchAllQuotas();
			const quotas: ProviderQuotaInfo[] = [];

			for (const [key, data] of result.quotas) {
				const [provider, email] = key.split(":");
				const providerMeta = Object.values(PROVIDER_METADATA).find(
					(p) => p.id === provider,
				);

				quotas.push({
					provider: providerMeta?.displayName ?? provider ?? "unknown",
					email: email ?? "unknown",
					models: data.models.map((m) => ({
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
				errors: result.errors.map((e) => ({
					provider: e.provider,
					error: e.error,
				})),
			};
		} catch (err) {
			return {
				success: false,
				quotas: [],
				errors: [
					{
						provider: "all",
						error: err instanceof Error ? err.message : String(err),
					},
				],
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

		const statuses = await detectionService.detectAllAgents(
			opts?.forceRefresh ?? false,
		);
		const agents: DetectedAgent[] = statuses.map((status) => ({
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
			opts.mode === "auto" ? "automatic" : "manual",
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
						(p) => p.id === provider || fileName.startsWith(p.id),
					);

					accounts.push({
						id: fileName.replace(".json", ""),
						name:
							content.email ?? content.account ?? fileName.replace(".json", ""),
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

	"universal.list": async () => {
		const { getUniversalProviderService } = await import(
			"../universal-provider-service.ts"
		);
		const service = getUniversalProviderService();
		const providers = service.getAllProviders().map(toProviderInfo);
		return { providers };
	},

	"universal.get": async (params: unknown) => {
		const { id } = params as { id: string };
		const { getUniversalProviderService } = await import(
			"../universal-provider-service.ts"
		);
		const service = getUniversalProviderService();
		const provider = service.getProvider(id);
		return { provider: provider ? toProviderInfo(provider) : null };
	},

	"universal.add": async (params: unknown) => {
		const opts = params as {
			name: string;
			baseURL: string;
			modelId?: string;
			color?: string;
			supportedAgents?: string[];
			isEnabled?: boolean;
		};
		const { getUniversalProviderService } = await import(
			"../universal-provider-service.ts"
		);
		const service = getUniversalProviderService();
		const provider = service.addProvider({
			name: opts.name,
			baseURL: opts.baseURL,
			modelId: opts.modelId ?? "",
			isBuiltIn: false,
			color: opts.color ?? "#6366F1",
			supportedAgents: opts.supportedAgents ?? [],
			isEnabled: opts.isEnabled ?? true,
		});
		return { success: true, provider: toProviderInfo(provider) };
	},

	"universal.update": async (params: unknown) => {
		const { id, ...updates } = params as { id: string; [key: string]: unknown };
		const { getUniversalProviderService } = await import(
			"../universal-provider-service.ts"
		);
		const service = getUniversalProviderService();
		const provider = service.updateProvider(id, updates);
		return {
			success: !!provider,
			provider: provider ? toProviderInfo(provider) : undefined,
		};
	},

	"universal.delete": async (params: unknown) => {
		const { id } = params as { id: string };
		const { getUniversalProviderService } = await import(
			"../universal-provider-service.ts"
		);
		const service = getUniversalProviderService();
		return { success: service.deleteProvider(id) };
	},

	"universal.setActive": async (params: unknown) => {
		const { agentId, providerId } = params as {
			agentId: string;
			providerId: string;
		};
		const { getUniversalProviderService } = await import(
			"../universal-provider-service.ts"
		);
		const service = getUniversalProviderService();
		service.setActiveProvider(agentId, providerId);
		return { success: true as const };
	},

	"universal.getActive": async (params: unknown) => {
		const { agentId } = params as { agentId: string };
		const { getUniversalProviderService } = await import(
			"../universal-provider-service.ts"
		);
		const service = getUniversalProviderService();
		const provider = service.getActiveProvider(agentId);
		return { provider: provider ? toProviderInfo(provider) : null };
	},

	"universal.storeKey": async (params: unknown) => {
		const { providerId, apiKey } = params as {
			providerId: string;
			apiKey: string;
		};
		const { getUniversalProviderService } = await import(
			"../universal-provider-service.ts"
		);
		const service = getUniversalProviderService();
		const validation = service.validateAPIKey(apiKey);
		if (!validation.valid) {
			return { success: false, error: validation.error };
		}
		service.storeAPIKey(providerId, apiKey);
		return { success: true };
	},

	"universal.hasKey": async (params: unknown) => {
		const { providerId } = params as { providerId: string };
		const { getUniversalProviderService } = await import(
			"../universal-provider-service.ts"
		);
		const service = getUniversalProviderService();
		return { hasKey: service.hasAPIKey(providerId) };
	},

	"oauth.start": async (params: unknown) => {
		const { provider, projectId } = params as {
			provider: string;
			projectId?: string;
		};
		const { ManagementAPIClient } = await import("../management-api.ts");
		const { parseProvider } = await import("../../models/provider.ts");

		const proxyState = getProcessState();
		if (!proxyState.running) {
			return { success: false, error: "Proxy not running" };
		}

		const aiProvider = parseProvider(provider);
		if (!aiProvider) {
			return { success: false, error: `Unknown provider: ${provider}` };
		}

		try {
			const client = new ManagementAPIClient({
				baseURL: `http://localhost:${proxyState.port}`,
				authKey: "quotio-cli-key",
			});
			const result = await client.getOAuthURL(aiProvider, { projectId });
			return {
				success: result.status === "success",
				url: result.url,
				state: result.state,
				error: result.error,
			};
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
			};
		}
	},

	"oauth.poll": async (params: unknown) => {
		const { state } = params as { state: string };
		const { ManagementAPIClient } = await import("../management-api.ts");

		const proxyState = getProcessState();
		if (!proxyState.running) {
			return { status: "error" as const, error: "Proxy not running" };
		}

		try {
			const client = new ManagementAPIClient({
				baseURL: `http://localhost:${proxyState.port}`,
				authKey: "quotio-cli-key",
			});
			const result = await client.pollOAuthStatus(state);

			if (result.status === "success") {
				return { status: "success" as const };
			}
			if (result.error) {
				return { status: "error" as const, error: result.error };
			}
			return { status: "pending" as const };
		} catch (err) {
			return {
				status: "error" as const,
				error: err instanceof Error ? err.message : String(err),
			};
		}
	},

	"stats.list": async (params: unknown) => {
		const opts = params as { provider?: string; minutes?: number } | undefined;
		let entries = requestTrackerService.getHistory();
		if (opts?.provider) {
			entries = entries.filter((e) => e.provider === opts.provider);
		}
		if (opts?.minutes) {
			const cutoff = new Date(
				Date.now() - opts.minutes * 60 * 1000,
			).toISOString();
			entries = entries.filter((e) => e.timestamp >= cutoff);
		}
		return { entries };
	},

	"stats.get": async () => {
		return { stats: requestTrackerService.getStats() };
	},

	"stats.add": async (params: unknown) => {
		const opts = params as {
			method: string;
			endpoint: string;
			provider?: string;
			model?: string;
			inputTokens?: number;
			outputTokens?: number;
			durationMs: number;
			statusCode?: number;
			requestSize?: number;
			responseSize?: number;
			errorMessage?: string;
		};
		const entry = createRequestLog({
			method: opts.method,
			endpoint: opts.endpoint,
			provider: opts.provider ?? null,
			model: opts.model ?? null,
			inputTokens: opts.inputTokens ?? null,
			outputTokens: opts.outputTokens ?? null,
			durationMs: opts.durationMs,
			statusCode: opts.statusCode ?? null,
			requestSize: opts.requestSize ?? 0,
			responseSize: opts.responseSize ?? 0,
			errorMessage: opts.errorMessage ?? null,
		});
		requestTrackerService.addEntry(entry);
		return { success: true as const };
	},

	"stats.clear": async () => {
		requestTrackerService.clear();
		return { success: true as const };
	},

	"stats.status": async () => {
		return requestTrackerService.getStatus();
	},

	"tunnel.start": async (params: unknown) => {
		const opts = params as { port: number };
		const { getCloudflaredService } = await import(
			"../tunnel/cloudflared-service.ts"
		);
		const service = getCloudflaredService();
		return await service.start(opts.port);
	},

	"tunnel.stop": async () => {
		const { getCloudflaredService } = await import(
			"../tunnel/cloudflared-service.ts"
		);
		const service = getCloudflaredService();
		await service.stop();
		return { success: true as const };
	},

	"tunnel.status": async () => {
		const { getCloudflaredService } = await import(
			"../tunnel/cloudflared-service.ts"
		);
		const service = getCloudflaredService();
		return service.getState();
	},

	"tunnel.installation": async () => {
		const { getCloudflaredService } = await import(
			"../tunnel/cloudflared-service.ts"
		);
		const service = getCloudflaredService();
		return service.getInstallation();
	},

	"fallback.getConfig": async () => {
		const { loadFallbackConfiguration } = await import(
			"../fallback/settings-service.ts"
		);
		const config = await loadFallbackConfiguration();
		return {
			isEnabled: config.isEnabled,
			virtualModels: config.virtualModels.map(toVirtualModelInfo),
		};
	},

	"fallback.setEnabled": async (params: unknown) => {
		const { enabled } = params as { enabled: boolean };
		const { setFallbackEnabled } = await import(
			"../fallback/settings-service.ts"
		);
		await setFallbackEnabled(enabled);
		return { success: true as const };
	},

	"fallback.listModels": async () => {
		const { getVirtualModels } = await import(
			"../fallback/settings-service.ts"
		);
		const models = await getVirtualModels();
		return { models: models.map(toVirtualModelInfo) };
	},

	"fallback.getModel": async (params: unknown) => {
		const { id } = params as { id: string };
		const { getVirtualModel } = await import("../fallback/settings-service.ts");
		const model = await getVirtualModel(id);
		return { model: model ? toVirtualModelInfo(model) : null };
	},

	"fallback.addModel": async (params: unknown) => {
		const { name } = params as { name: string };
		const { addVirtualModel } = await import("../fallback/settings-service.ts");
		const model = await addVirtualModel(name);
		return {
			success: model !== null,
			model: model ? toVirtualModelInfo(model) : undefined,
		};
	},

	"fallback.removeModel": async (params: unknown) => {
		const { id } = params as { id: string };
		const { removeVirtualModel } = await import(
			"../fallback/settings-service.ts"
		);
		const success = await removeVirtualModel(id);
		return { success };
	},

	"fallback.updateModel": async (params: unknown) => {
		const opts = params as { id: string; name?: string; isEnabled?: boolean };
		const { getVirtualModel, updateVirtualModel, renameVirtualModel } =
			await import("../fallback/settings-service.ts");

		const model = await getVirtualModel(opts.id);
		if (!model) {
			return { success: false };
		}

		if (opts.name !== undefined && opts.name !== model.name) {
			const renamed = await renameVirtualModel(opts.id, opts.name);
			if (!renamed) {
				return { success: false };
			}
		}

		if (opts.isEnabled !== undefined && opts.isEnabled !== model.isEnabled) {
			const updatedModel = await getVirtualModel(opts.id);
			if (updatedModel) {
				const success = await updateVirtualModel({
					...updatedModel,
					isEnabled: opts.isEnabled,
				});
				return { success };
			}
		}

		return { success: true };
	},

	"fallback.addEntry": async (params: unknown) => {
		const { modelId, provider, modelName } = params as {
			modelId: string;
			provider: string;
			modelName: string;
		};
		const { addFallbackEntry } = await import(
			"../fallback/settings-service.ts"
		);
		const { parseProvider } = await import("../../models/provider.ts");

		const aiProvider = parseProvider(provider);
		if (!aiProvider) {
			return { success: false };
		}

		const entry = await addFallbackEntry(modelId, aiProvider, modelName);
		return {
			success: entry !== null,
			entry: entry ? toFallbackEntryInfo(entry) : undefined,
		};
	},

	"fallback.removeEntry": async (params: unknown) => {
		const { modelId, entryId } = params as { modelId: string; entryId: string };
		const { removeFallbackEntry } = await import(
			"../fallback/settings-service.ts"
		);
		const success = await removeFallbackEntry(modelId, entryId);
		return { success };
	},

	"fallback.moveEntry": async (params: unknown) => {
		const { modelId, fromIndex, toIndex } = params as {
			modelId: string;
			fromIndex: number;
			toIndex: number;
		};
		const { moveFallbackEntry } = await import(
			"../fallback/settings-service.ts"
		);
		const success = await moveFallbackEntry(modelId, fromIndex, toIndex);
		return { success };
	},

	"fallback.getRouteStates": async () => {
		const { getAllRouteStates } = await import(
			"../fallback/settings-service.ts"
		);
		const states = getAllRouteStates();
		return {
			states: states.map((s) => ({
				virtualModelName: s.virtualModelName,
				currentEntryIndex: s.currentEntryIndex,
				currentEntry: toFallbackEntryInfo(s.currentEntry),
				lastUpdated: s.lastUpdated.toISOString(),
				totalEntries: s.totalEntries,
			})),
		};
	},

	"fallback.clearRouteStates": async () => {
		const { clearAllRouteStates } = await import(
			"../fallback/settings-service.ts"
		);
		clearAllRouteStates();
		return { success: true as const };
	},

	"fallback.export": async () => {
		const { exportConfiguration } = await import(
			"../fallback/settings-service.ts"
		);
		const json = await exportConfiguration();
		return { json };
	},

	"fallback.import": async (params: unknown) => {
		const { json } = params as { json: string };
		const { importConfiguration } = await import(
			"../fallback/settings-service.ts"
		);
		const success = await importConfiguration(json);
		return { success };
	},

	"proxyConfig.getAll": async () => {
		const { ManagementAPIClient } = await import("../management-api.ts");
		const proxyState = getProcessState();

		if (!proxyState.running) {
			return { success: false, error: "Proxy not running" };
		}

		const client = new ManagementAPIClient({
			baseURL: `http://localhost:${proxyState.port}`,
			authKey: "quotio-cli-key",
		});

		try {
			const [
				config,
				debug,
				routingStrategy,
				requestRetry,
				maxRetryInterval,
				proxyURL,
				loggingToFile,
			] = await Promise.all([
				client.fetchConfig(),
				client.getDebug().catch(() => false),
				client.getRoutingStrategy().catch(() => "round-robin"),
				client.getRequestRetry().catch(() => 3),
				client.getMaxRetryInterval().catch(() => 60),
				client.getProxyURL().catch(() => ""),
				client.getLoggingToFile().catch(() => false),
			]);

			return {
				success: true,
				config: {
					...config,
					debug,
					routingStrategy,
					requestRetry,
					maxRetryInterval,
					proxyURL,
					loggingToFile,
				},
			};
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
			};
		}
	},

	"proxyConfig.get": async (params: unknown) => {
		const { key } = params as { key: string };
		const { ManagementAPIClient } = await import("../management-api.ts");
		const proxyState = getProcessState();

		if (!proxyState.running) {
			return { success: false, error: "Proxy not running" };
		}

		const client = new ManagementAPIClient({
			baseURL: `http://localhost:${proxyState.port}`,
			authKey: "quotio-cli-key",
		});

		try {
			let value: unknown;
			switch (key) {
				case "debug":
					value = await client.getDebug();
					break;
				case "routingStrategy":
					value = await client.getRoutingStrategy();
					break;
				case "requestRetry":
					value = await client.getRequestRetry();
					break;
				case "maxRetryInterval":
					value = await client.getMaxRetryInterval();
					break;
				case "proxyURL":
					value = await client.getProxyURL();
					break;
				case "loggingToFile":
					value = await client.getLoggingToFile();
					break;
				default:
					return { success: false, error: `Unknown config key: ${key}` };
			}
			return { success: true, key, value };
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
			};
		}
	},

	"proxyConfig.set": async (params: unknown) => {
		const { key, value } = params as { key: string; value: unknown };
		const { ManagementAPIClient } = await import("../management-api.ts");
		const proxyState = getProcessState();

		if (!proxyState.running) {
			return { success: false, error: "Proxy not running" };
		}

		const client = new ManagementAPIClient({
			baseURL: `http://localhost:${proxyState.port}`,
			authKey: "quotio-cli-key",
		});

		try {
			switch (key) {
				case "debug":
					await client.setDebug(Boolean(value));
					break;
				case "routingStrategy":
					await client.setRoutingStrategy(
						value as "round-robin" | "fill-first",
					);
					break;
				case "requestRetry":
					await client.setRequestRetry(Number(value));
					break;
				case "maxRetryInterval":
					await client.setMaxRetryInterval(Number(value));
					break;
				case "proxyURL":
					if (value) {
						await client.setProxyURL(String(value));
					} else {
						await client.deleteProxyURL();
					}
					break;
				case "loggingToFile":
					await client.setLoggingToFile(Boolean(value));
					break;
				case "quotaExceededSwitchProject":
					await client.setQuotaExceededSwitchProject(Boolean(value));
					break;
				case "quotaExceededSwitchPreviewModel":
					await client.setQuotaExceededSwitchPreviewModel(Boolean(value));
					break;
				default:
					return { success: false, error: `Unknown config key: ${key}` };
			}
			return { success: true };
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
			};
		}
	},

	"auth.delete": async (params: unknown) => {
		const { name } = params as { name: string };
		const { ManagementAPIClient } = await import("../management-api.ts");
		const proxyState = getProcessState();

		if (!proxyState.running) {
			return { success: false, error: "Proxy not running" };
		}

		const client = new ManagementAPIClient({
			baseURL: `http://localhost:${proxyState.port}`,
			authKey: "quotio-cli-key",
		});

		try {
			await client.deleteAuthFile(name);
			return { success: true };
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
			};
		}
	},

	"auth.deleteAll": async () => {
		const { ManagementAPIClient } = await import("../management-api.ts");
		const proxyState = getProcessState();

		if (!proxyState.running) {
			return { success: false, error: "Proxy not running" };
		}

		const client = new ManagementAPIClient({
			baseURL: `http://localhost:${proxyState.port}`,
			authKey: "quotio-cli-key",
		});

		try {
			await client.deleteAllAuthFiles();
			return { success: true };
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
			};
		}
	},

	"auth.setDisabled": async (params: unknown) => {
		const { name, disabled } = params as { name: string; disabled: boolean };
		const { ManagementAPIClient } = await import("../management-api.ts");
		const proxyState = getProcessState();

		if (!proxyState.running) {
			return { success: false, error: "Proxy not running" };
		}

		const client = new ManagementAPIClient({
			baseURL: `http://localhost:${proxyState.port}`,
			authKey: "quotio-cli-key",
		});

		try {
			await client.setAuthFileDisabled(name, disabled);
			return { success: true };
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
			};
		}
	},

	"auth.models": async (params: unknown) => {
		const { name } = params as { name: string };
		const proxyState = getProcessState();

		if (!proxyState.running) {
			return { success: false, error: "Proxy not running", models: [] };
		}

		try {
			const controller = new AbortController();
			const timeoutId = setTimeout(() => controller.abort(), 30000);

			const encoded = encodeURIComponent(name);
			const response = await fetch(
				`http://localhost:${proxyState.port}/auth-files/models?name=${encoded}`,
				{
					method: "GET",
					headers: {
						Authorization: "Bearer quotio-cli-key",
						Connection: "close",
					},
					signal: controller.signal,
				},
			);

			clearTimeout(timeoutId);

			if (!response.ok) {
				return {
					success: false,
					error: `HTTP ${response.status}`,
					models: [],
				};
			}

			const data = (await response.json()) as {
				models?: Array<{ id?: string; model_id?: string; name?: string; owned_by?: string; type?: string }>;
			};
			const models = (data.models ?? []).map((m) => ({
				id: m.id ?? m.model_id ?? "",
				name: m.name ?? m.model_id ?? m.id ?? "",
				ownedBy: m.owned_by ?? null,
				provider: m.type ?? null,
			}));

			return { success: true, models };
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
				models: [],
			};
		}
	},

	"apiKeys.list": async () => {
		const { ManagementAPIClient } = await import("../management-api.ts");
		const proxyState = getProcessState();

		if (!proxyState.running) {
			return { success: false, error: "Proxy not running", keys: [] };
		}

		const client = new ManagementAPIClient({
			baseURL: `http://localhost:${proxyState.port}`,
			authKey: "quotio-cli-key",
		});

		try {
			const keys = await client.fetchAPIKeys();
			return { success: true, keys };
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
				keys: [],
			};
		}
	},

	"apiKeys.add": async () => {
		const { ManagementAPIClient } = await import("../management-api.ts");
		const proxyState = getProcessState();

		if (!proxyState.running) {
			return { success: false, error: "Proxy not running" };
		}

		const client = new ManagementAPIClient({
			baseURL: `http://localhost:${proxyState.port}`,
			authKey: "quotio-cli-key",
		});

		try {
			const key = await client.addAPIKey();
			return { success: true, key };
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
			};
		}
	},

	"apiKeys.delete": async (params: unknown) => {
		const { key } = params as { key: string };
		const { ManagementAPIClient } = await import("../management-api.ts");
		const proxyState = getProcessState();

		if (!proxyState.running) {
			return { success: false, error: "Proxy not running" };
		}

		const client = new ManagementAPIClient({
			baseURL: `http://localhost:${proxyState.port}`,
			authKey: "quotio-cli-key",
		});

		try {
			await client.deleteAPIKey(key);
			return { success: true };
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
			};
		}
	},

	"proxy.healthCheck": async () => {
		const { ManagementAPIClient } = await import("../management-api.ts");
		const proxyState = getProcessState();

		if (!proxyState.running) {
			return { healthy: false, error: "Proxy not running" };
		}

		const client = new ManagementAPIClient({
			baseURL: `http://localhost:${proxyState.port}`,
			authKey: "quotio-cli-key",
		});

		try {
			const healthy = await client.healthCheck();
			return { healthy };
		} catch (err) {
			return {
				healthy: false,
				error: err instanceof Error ? err.message : String(err),
			};
		}
	},

	"proxy.latestVersion": async () => {
		const proxyState = getProcessState();

		if (!proxyState.running) {
			return { success: false, error: "Proxy not running" };
		}

		try {
			const controller = new AbortController();
			const timeoutId = setTimeout(() => controller.abort(), 30000);

			const response = await fetch(
				`http://localhost:${proxyState.port}/latest-version`,
				{
					method: "GET",
					headers: {
						Authorization: "Bearer quotio-cli-key",
						Connection: "close",
					},
					signal: controller.signal,
				},
			);

			clearTimeout(timeoutId);

			if (!response.ok) {
				return {
					success: false,
					error: `HTTP ${response.status}`,
				};
			}

			const data = (await response.json()) as { "latest-version"?: string };
			return {
				success: true,
				latestVersion: data["latest-version"] ?? "",
			};
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
			};
		}
	},

	"logs.fetch": async (params: unknown) => {
		const opts = params as { after?: number } | undefined;
		const { ManagementAPIClient } = await import("../management-api.ts");
		const proxyState = getProcessState();

		if (!proxyState.running) {
			return {
				success: false,
				error: "Proxy not running",
				logs: [],
				total: 0,
				lastId: 0,
			};
		}

		const client = new ManagementAPIClient({
			baseURL: `http://localhost:${proxyState.port}`,
			authKey: "quotio-cli-key",
		});

		try {
			const response = await client.fetchLogs(opts?.after);
			return { success: true, ...response };
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
				logs: [],
				total: 0,
				lastId: 0,
			};
		}
	},

	"logs.clear": async () => {
		const { ManagementAPIClient } = await import("../management-api.ts");
		const proxyState = getProcessState();

		if (!proxyState.running) {
			return { success: false, error: "Proxy not running" };
		}

		const client = new ManagementAPIClient({
			baseURL: `http://localhost:${proxyState.port}`,
			authKey: "quotio-cli-key",
		});

		try {
			await client.clearLogs();
			return { success: true };
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
			};
		}
	},

	"api.call": async (params: unknown) => {
		const opts = params as {
			authIndex?: string;
			method: string;
			url: string;
			header?: Record<string, string>;
			data?: string;
		};
		const proxyState = getProcessState();

		if (!proxyState.running) {
			return { success: false, error: "Proxy not running" };
		}

		try {
			const controller = new AbortController();
			const timeoutId = setTimeout(() => controller.abort(), 60000);

			const requestUrl = `http://localhost:${proxyState.port}/api-call`;
			const requestBody = JSON.stringify({
				auth_index: opts.authIndex,
				method: opts.method,
				url: opts.url,
				header: opts.header,
				data: opts.data,
			});

			const response = await fetch(requestUrl, {
				method: "POST",
				headers: {
					Authorization: "Bearer quotio-cli-key",
					"Content-Type": "application/json",
					Connection: "close",
				},
				body: requestBody,
				signal: controller.signal,
			});

			clearTimeout(timeoutId);

			const text = await response.text();
			let result: {
				status_code: number;
				header?: Record<string, string[]>;
				body?: string;
			};

			try {
				result = JSON.parse(text);
			} catch {
				return {
					success: false,
					error: "Failed to parse response",
				};
			}

			return {
				success: true,
				statusCode: result.status_code,
				header: result.header,
				body: result.body,
			};
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
			};
		}
	},

	"remote.setConfig": async (params: unknown) => {
		const opts = params as {
			endpointURL: string;
			displayName?: string;
			managementKey: string;
			verifySSL?: boolean;
			timeoutSeconds?: number;
		};
		const store = await loadConfigStore();
		store.remoteConfig = {
			endpointURL: opts.endpointURL,
			displayName: opts.displayName ?? "Remote Server",
			verifySSL: opts.verifySSL ?? true,
			timeoutSeconds: opts.timeoutSeconds ?? 30,
		};
		store.remoteManagementKey = opts.managementKey;
		await saveConfigStore();
		return { success: true };
	},

	"remote.getConfig": async () => {
		const store = await loadConfigStore();
		const config = store.remoteConfig as
			| {
					endpointURL: string;
					displayName: string;
					verifySSL: boolean;
					timeoutSeconds: number;
			  }
			| undefined;
		return {
			config: config ?? null,
			hasKey: Boolean(store.remoteManagementKey),
		};
	},

	"remote.clearConfig": async () => {
		const store = await loadConfigStore();
		store.remoteConfig = undefined;
		store.remoteManagementKey = undefined;
		await saveConfigStore();
		return { success: true };
	},

	"remote.testConnection": async (params: unknown) => {
		const opts = params as {
			endpointURL: string;
			managementKey: string;
			timeoutSeconds?: number;
		};

		try {
			const controller = new AbortController();
			const timeout = (opts.timeoutSeconds ?? 30) * 1000;
			const timeoutId = setTimeout(() => controller.abort(), timeout);

			let baseURL = opts.endpointURL.replace(/\/+$/, "");
			if (!baseURL.endsWith("/v0/management")) {
				if (baseURL.endsWith("/v0")) {
					baseURL += "/management";
				} else {
					baseURL += "/v0/management";
				}
			}

			const response = await fetch(`${baseURL}/health`, {
				method: "GET",
				headers: {
					Authorization: `Bearer ${opts.managementKey}`,
					Connection: "close",
				},
				signal: controller.signal,
			});

			clearTimeout(timeoutId);

			return {
				success: response.ok,
				statusCode: response.status,
				error: response.ok ? undefined : `HTTP ${response.status}`,
			};
		} catch (err) {
			return {
				success: false,
				error: err instanceof Error ? err.message : String(err),
			};
		}
	},
};

export async function startDaemon(options?: {
	foreground?: boolean;
}): Promise<void> {
	const pidPath = ConfigFiles.pidFile();

	if (existsSync(pidPath)) {
		const existingPid = Number.parseInt(
			readFileSync(pidPath, "utf-8").trim(),
			10,
		);
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

export { isServerRunning, getConnectionInfo, getConnectionCount };
