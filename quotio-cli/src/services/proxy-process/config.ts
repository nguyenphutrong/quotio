import {
	getAuthDir,
	getProxyConfigPath,
	getProxyLogDir,
} from "../proxy-binary/constants.ts";

export interface ProxyConfig {
	host: string;
	port: number;
	authDir: string;
	proxyUrl: string;
	apiKeys: string[];
	debug: boolean;
	loggingToFile: boolean;
	usageStatisticsEnabled: boolean;
	routing: {
		strategy: "round-robin" | "fill-first";
	};
	quotaExceeded: {
		switchProject: boolean;
		switchPreviewModel: boolean;
	};
	requestRetry: number;
	maxRetryInterval: number;
	remoteManagement?: {
		allowRemote: boolean;
		secretKey: string;
	};
}

export function generateDefaultConfig(port = 8217): ProxyConfig {
	return {
		host: "127.0.0.1",
		port,
		authDir: getAuthDir(),
		proxyUrl: "",
		apiKeys: [`quotio-cli-${crypto.randomUUID()}`],
		debug: false,
		loggingToFile: false,
		usageStatisticsEnabled: true,
		routing: {
			strategy: "round-robin",
		},
		quotaExceeded: {
			switchProject: true,
			switchPreviewModel: true,
		},
		requestRetry: 3,
		maxRetryInterval: 30,
	};
}

export function configToYaml(config: ProxyConfig): string {
	const lines: string[] = [
		`host: "${config.host}"`,
		`port: ${config.port}`,
		`auth-dir: "${config.authDir}"`,
		`proxy-url: "${config.proxyUrl}"`,
		"",
		"api-keys:",
		...config.apiKeys.map((key) => `  - "${key}"`),
		"",
	];

	if (config.remoteManagement) {
		lines.push(
			"remote-management:",
			`  allow-remote: ${config.remoteManagement.allowRemote}`,
			`  secret-key: "${config.remoteManagement.secretKey}"`,
			"",
		);
	}

	lines.push(
		`debug: ${config.debug}`,
		`logging-to-file: ${config.loggingToFile}`,
		`usage-statistics-enabled: ${config.usageStatisticsEnabled}`,
		"",
		"routing:",
		`  strategy: "${config.routing.strategy}"`,
		"",
		"quota-exceeded:",
		`  switch-project: ${config.quotaExceeded.switchProject}`,
		`  switch-preview-model: ${config.quotaExceeded.switchPreviewModel}`,
		"",
		`request-retry: ${config.requestRetry}`,
		`max-retry-interval: ${config.maxRetryInterval}`,
	);

	return lines.join("\n");
}

export async function ensureConfigExists(port = 8217): Promise<string> {
	const configPath = getProxyConfigPath();
	const file = Bun.file(configPath);

	if (await file.exists()) {
		return configPath;
	}

	const config = generateDefaultConfig(port);
	await Bun.write(configPath, configToYaml(config));
	return configPath;
}

export async function readConfig(): Promise<ProxyConfig | null> {
	const configPath = getProxyConfigPath();
	const file = Bun.file(configPath);

	if (!(await file.exists())) {
		return null;
	}

	try {
		const content = await file.text();
		return parseConfigYaml(content);
	} catch {
		return null;
	}
}

function parseConfigYaml(yaml: string): ProxyConfig {
	const config = generateDefaultConfig();

	const hostMatch = yaml.match(/^host:\s*"?([^"\n]+)"?/m);
	if (hostMatch?.[1]) config.host = hostMatch[1];

	const portMatch = yaml.match(/^port:\s*(\d+)/m);
	if (portMatch?.[1]) config.port = Number.parseInt(portMatch[1], 10);

	const authDirMatch = yaml.match(/^auth-dir:\s*"?([^"\n]+)"?/m);
	if (authDirMatch?.[1]) config.authDir = authDirMatch[1];

	const proxyUrlMatch = yaml.match(/^proxy-url:\s*"?([^"\n]*)"?/m);
	if (proxyUrlMatch?.[1]) config.proxyUrl = proxyUrlMatch[1];

	const debugMatch = yaml.match(/^debug:\s*(true|false)/m);
	if (debugMatch?.[1]) config.debug = debugMatch[1] === "true";

	const loggingMatch = yaml.match(/^logging-to-file:\s*(true|false)/m);
	if (loggingMatch?.[1]) config.loggingToFile = loggingMatch[1] === "true";

	const strategyMatch = yaml.match(/strategy:\s*"?(round-robin|fill-first)"?/m);
	if (strategyMatch?.[1]) {
		config.routing.strategy = strategyMatch[1] as "round-robin" | "fill-first";
	}

	const retryMatch = yaml.match(/^request-retry:\s*(\d+)/m);
	if (retryMatch?.[1]) config.requestRetry = Number.parseInt(retryMatch[1], 10);

	const maxRetryMatch = yaml.match(/^max-retry-interval:\s*(\d+)/m);
	if (maxRetryMatch?.[1])
		config.maxRetryInterval = Number.parseInt(maxRetryMatch[1], 10);

	return config;
}

export async function updateConfigPort(port: number): Promise<void> {
	const configPath = getProxyConfigPath();
	const file = Bun.file(configPath);

	if (!(await file.exists())) {
		await ensureConfigExists(port);
		return;
	}

	let content = await file.text();
	content = content.replace(/^port:\s*\d+/m, `port: ${port}`);
	await Bun.write(configPath, content);
}

export async function ensureLogDir(): Promise<string> {
	const logDir = getProxyLogDir();
	await Bun.spawn(["mkdir", "-p", logDir]).exited;
	return logDir;
}
