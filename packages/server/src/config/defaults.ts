import type { Config } from './schema.ts';

export const DEFAULT_CONFIG: Config = {
	host: '127.0.0.1',
	port: 18317,
	tls: {
		enable: false,
	},
	remoteManagement: {
		allowRemote: false,
		disableControlPanel: false,
	},
	authDir: '~/.cli-proxy-api',
	configDir: '~/.config/quotio',
	apiKeys: [],
	debug: false,
	loggingToFile: false,
	routing: {
		strategy: 'round-robin',
	},
	requestRetry: 3,
	maxRetryInterval: 30,
	quotaExceeded: {
		switchProject: true,
		switchPreviewModel: true,
	},
};
