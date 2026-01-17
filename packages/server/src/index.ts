import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { type FallbackConfiguration, deserializeFallbackConfiguration } from '@quotio/core';
import { createApp } from './api/index.js';
import { AuthManager } from './auth/index.js';
import { loadConfig } from './config/index.js';
import { ProxyDispatcher } from './proxy/index.js';
import { FileTokenStore } from './store/index.js';

function expandPath(p: string): string {
	if (p.startsWith('~/') || p === '~') {
		return path.join(os.homedir(), p.slice(1));
	}
	return p;
}

function loadFallbackConfig(configDir: string): FallbackConfiguration | undefined {
	const fallbackConfigPath = path.join(configDir, 'fallback-config.json');

	try {
		if (!fs.existsSync(fallbackConfigPath)) {
			return undefined;
		}

		const content = fs.readFileSync(fallbackConfigPath, 'utf-8');
		return deserializeFallbackConfiguration(content);
	} catch (err) {
		console.warn('[server] Failed to load fallback config:', err);
		return undefined;
	}
}

async function main() {
	const config = await loadConfig();

	const authDir = expandPath(config.authDir);
	const configDir = expandPath(config.configDir);

	const store = new FileTokenStore({
		authDir,
		configDir,
	});

	const authManager = new AuthManager(config, store);

	const fallbackConfig = loadFallbackConfig(configDir);

	const dispatcher = new ProxyDispatcher(store, {
		debug: config.debug,
		fallbackConfig,
	});

	const app = createApp({ config, authManager, store, dispatcher });

	const server = Bun.serve({
		port: config.port,
		hostname: config.host || '0.0.0.0',
		fetch: app.fetch,
	});

	console.log('🚀 quotio-server v0.1.0');
	console.log('   Listening on http://' + server.hostname + ':' + String(server.port));
	console.log('   Auth directory: ' + authDir);
	console.log('   Config directory: ' + configDir);
	console.log('   Debug: ' + String(config.debug));

	if (fallbackConfig?.isEnabled) {
		const modelCount = fallbackConfig.virtualModels.filter((vm) => vm.isEnabled).length;
		console.log('   Fallback: enabled (' + String(modelCount) + ' virtual models)');
	}
}

main().catch((err) => {
	console.error('Failed to start server:', err);
	process.exit(1);
});
