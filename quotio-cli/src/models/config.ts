import type { AIProvider } from "./provider.ts";

export interface RoutingConfig {
	strategy: "round-robin" | "fill-first";
}

export interface QuotaExceededConfig {
	switchProject: boolean;
	switchPreviewModel: boolean;
}

export interface RemoteManagementConfig {
	allowRemote: boolean;
	secretKey: string;
	disableControlPanel: boolean;
}

export interface AppConfig {
	host: string;
	port: number;
	authDir: string;
	proxyURL: string;
	apiKeys: string[];
	debug: boolean;
	loggingToFile: boolean;
	usageStatisticsEnabled: boolean;
	requestRetry: number;
	maxRetryInterval: number;
	wsAuth: boolean;
	routing: RoutingConfig;
	quotaExceeded: QuotaExceededConfig;
	remoteManagement: RemoteManagementConfig;
}

export interface ProxyStatus {
	running: boolean;
	port: number;
}

export interface QuotioConfig {
	proxy: {
		host: string;
		port: number;
		authDir: string;
		autoStart: boolean;
	};
	quota: {
		refreshInterval: number;
		cacheTimeout: number;
		enabledProviders: AIProvider[];
	};
	output: {
		format: "table" | "json" | "plain";
		colors: boolean;
		verbose: boolean;
	};
}

export function getProxyEndpoint(status: ProxyStatus): string {
	return `http://localhost:${status.port}/v1`;
}

export function parseAppConfig(json: Record<string, unknown>): AppConfig {
	return {
		host: String(json.host ?? ""),
		port: Number(json.port ?? 8317),
		authDir: String(json["auth-dir"] ?? "~/.cli-proxy-api"),
		proxyURL: String(json["proxy-url"] ?? ""),
		apiKeys: (json["api-keys"] as string[]) ?? [],
		debug: Boolean(json.debug),
		loggingToFile: Boolean(json["logging-to-file"]),
		usageStatisticsEnabled: Boolean(json["usage-statistics-enabled"] ?? true),
		requestRetry: Number(json["request-retry"] ?? 3),
		maxRetryInterval: Number(json["max-retry-interval"] ?? 30),
		wsAuth: Boolean(json["ws-auth"]),
		routing: parseRoutingConfig(
			(json.routing as Record<string, unknown>) ?? {},
		),
		quotaExceeded: parseQuotaExceededConfig(
			(json["quota-exceeded"] as Record<string, unknown>) ?? {},
		),
		remoteManagement: parseRemoteManagementConfig(
			(json["remote-management"] as Record<string, unknown>) ?? {},
		),
	};
}

function parseRoutingConfig(json: Record<string, unknown>): RoutingConfig {
	return {
		strategy: (json.strategy as "round-robin" | "fill-first") ?? "round-robin",
	};
}

function parseQuotaExceededConfig(
	json: Record<string, unknown>,
): QuotaExceededConfig {
	return {
		switchProject: Boolean(json["switch-project"] ?? true),
		switchPreviewModel: Boolean(json["switch-preview-model"] ?? true),
	};
}

function parseRemoteManagementConfig(
	json: Record<string, unknown>,
): RemoteManagementConfig {
	return {
		allowRemote: Boolean(json["allow-remote"]),
		secretKey: String(json["secret-key"] ?? ""),
		disableControlPanel: Boolean(json["disable-control-panel"]),
	};
}

export function createDefaultConfig(): QuotioConfig {
	return {
		proxy: {
			host: "localhost",
			port: 8317,
			authDir: "~/.cli-proxy-api",
			autoStart: false,
		},
		quota: {
			refreshInterval: 300,
			cacheTimeout: 60,
			enabledProviders: [],
		},
		output: {
			format: "table",
			colors: true,
			verbose: false,
		},
	};
}

export function createDefaultProxyStatus(): ProxyStatus {
	return {
		running: false,
		port: 8317,
	};
}
