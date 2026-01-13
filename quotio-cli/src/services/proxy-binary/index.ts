export {
	BUNDLED_PROXY_VERSION,
	PROXY_BINARY_NAME,
	getProxyDataDir,
	getProxyBinaryDir,
	getProxyBinaryPath,
	getProxyConfigPath,
	getProxyLogDir,
	getProxyPidPath,
	getAuthDir,
} from "./constants.ts";

export {
	type ProxyBinaryInfo,
	ensureDirectories,
	getBinaryInfo,
	extractEmbeddedBinary,
	verifyBinary,
	removeBinary,
} from "./manager.ts";
