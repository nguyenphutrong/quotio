export const BUNDLED_PROXY_VERSION = "6.6.100-0";

export const PROXY_BINARY_NAME = "cli-proxy-api-plus";

export function getProxyDataDir(): string {
	const home = process.env.HOME ?? Bun.env.HOME ?? "";
	return `${home}/.quotio-cli`;
}

export function getProxyBinaryDir(): string {
	return `${getProxyDataDir()}/bin`;
}

export function getProxyBinaryPath(): string {
	const isWindows = process.platform === "win32";
	return `${getProxyBinaryDir()}/${PROXY_BINARY_NAME}${isWindows ? ".exe" : ""}`;
}

export function getProxyConfigPath(): string {
	return `${getProxyDataDir()}/config.yaml`;
}

export function getProxyLogDir(): string {
	return `${getProxyDataDir()}/logs`;
}

export function getProxyPidPath(): string {
	return `${getProxyDataDir()}/proxy.pid`;
}

export function getAuthDir(): string {
	const home = process.env.HOME ?? Bun.env.HOME ?? "";
	return `${home}/.cli-proxy-api`;
}
