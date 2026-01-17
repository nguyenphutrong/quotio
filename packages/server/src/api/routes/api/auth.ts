import { Hono } from 'hono';
import {
	pollKiroAwsDeviceCode,
	startKiroAwsDeviceCode,
} from '../../../auth/device-code/kiro-aws.js';
import type { AuthManager, ProviderType } from '../../../auth/index.js';
import type { StoredAuthFile, TokenStore } from '../../../store/types.js';

interface AuthRoutesDeps {
	authManager: AuthManager;
	store: TokenStore;
}

function formatAuthFile(file: StoredAuthFile) {
	return {
		id: file.id,
		provider: file.provider,
		email: file.email,
		name: file.name,
		status: file.status,
		disabled: file.disabled,
		expires_at: file.expiresAt,
		is_expired: file.expiresAt ? new Date(file.expiresAt) < new Date() : false,
		created_at: file.createdAt,
		updated_at: file.updatedAt,
	};
}

function normalizeProvider(provider: string): string {
	switch (provider) {
		case 'gemini-cli':
			return 'gemini';
		case 'codex':
			return 'openai';
		case 'github-copilot':
			return 'copilot';
		default:
			return provider;
	}
}

function getModelsForProvider(provider: string): string[] {
	switch (normalizeProvider(provider)) {
		case 'claude':
			return [
				'claude-3-5-sonnet-20241022',
				'claude-3-5-haiku-20241022',
				'claude-3-opus-20240229',
				'claude-sonnet-4-20250514',
				'claude-opus-4-20250514',
			];
		case 'gemini':
			return [
				'gemini-2.0-flash-exp',
				'gemini-2.0-flash-thinking-exp',
				'gemini-1.5-pro',
				'gemini-1.5-flash',
			];
		case 'openai':
			return ['gpt-4o', 'gpt-4o-mini', 'o1', 'o1-mini', 'o3', 'o3-mini'];
		case 'copilot':
			return ['gpt-4o', 'gpt-4o-mini', 'claude-3.5-sonnet', 'o1', 'o1-mini'];
		case 'qwen':
			return ['qwen-turbo', 'qwen-plus', 'qwen-max', 'qwen-coder-turbo', 'qwen-coder-plus'];
		case 'iflow':
			return ['claude-3-5-sonnet', 'claude-3-opus', 'gpt-4o', 'gpt-4-turbo'];
		default:
			return [];
	}
}

function ownerForProvider(provider: string): string | null {
	switch (normalizeProvider(provider)) {
		case 'claude':
			return 'anthropic';
		case 'gemini':
			return 'google';
		case 'openai':
			return 'openai';
		case 'copilot':
			return 'github';
		case 'qwen':
			return 'qwen';
		case 'iflow':
			return 'iflow';
		case 'kiro':
			return 'kiro';
		case 'vertex':
			return 'google';
		default:
			return null;
	}
}

export function authRoutes(deps: AuthRoutesDeps): Hono {
	const app = new Hono();
	const { authManager, store } = deps;

	app.get('/auth', async (c) => {
		const authFiles = await authManager.listAuthFiles();
		return c.json({ auth_files: authFiles.map(formatAuthFile) });
	});

	app.get('/auth/:provider', async (c) => {
		const provider = c.req.param('provider');
		const authFile = await authManager.getAuthFile(provider);
		if (!authFile) {
			return c.json({ error: 'Not authenticated' }, 404);
		}
		return c.json(formatAuthFile(authFile));
	});

	app.delete('/auth/:id', async (c) => {
		const id = c.req.param('id');
		await authManager.deleteAuthFile(id);
		return c.json({ success: true });
	});

	app.delete('/auth', async (c) => {
		const authFiles = await authManager.listAuthFiles();
		for (const file of authFiles) {
			await authManager.deleteAuthFile(file.id);
		}
		return c.json({ success: true, deleted: authFiles.length });
	});

	app.put('/auth/:id/disabled', async (c) => {
		const id = c.req.param('id');
		const body = (await c.req.json().catch(() => ({
			disabled: undefined,
		}))) as { disabled?: boolean };
		if (typeof body.disabled !== 'boolean') {
			return c.json({ error: 'Missing disabled flag' }, 400);
		}
		const authFile = await store.getAuthFile(id);
		if (!authFile) {
			return c.json({ error: 'Auth file not found' }, 404);
		}
		authFile.disabled = body.disabled;
		authFile.updatedAt = new Date().toISOString();
		await store.saveAuthFile(authFile);
		return c.json({ success: true, id, disabled: body.disabled });
	});

	app.get('/auth/:id/models', async (c) => {
		const id = c.req.param('id');
		const authFile = await store.getAuthFile(id);
		if (!authFile) {
			return c.json({ error: 'Auth file not found', models: [] }, 404);
		}
		const models = getModelsForProvider(authFile.provider).map((modelId) => ({
			id: modelId,
			name: modelId,
			owned_by: ownerForProvider(authFile.provider),
			provider: normalizeProvider(authFile.provider),
		}));
		return c.json({ models });
	});

	app.post('/auth/refresh', async (c) => {
		const body = (await c.req.json().catch(() => ({
			provider: undefined,
		}))) as { provider?: string };
		const provider = body.provider;
		const authFiles = await authManager.listAuthFiles();
		const targets = provider ? authFiles.filter((file) => file.provider === provider) : authFiles;

		if (provider && targets.length === 0) {
			return c.json(
				{ success: false, refreshed: 0, errors: [{ id: provider, error: 'Provider not found' }] },
				404,
			);
		}

		let refreshed = 0;
		const errors: Array<{ id: string; error: string }> = [];

		for (const file of targets) {
			if (file.disabled) continue;
			try {
				await authManager.refreshIfNeeded(file);
				refreshed += 1;
			} catch (err) {
				errors.push({
					id: file.id,
					error: err instanceof Error ? err.message : String(err),
				});
			}
		}

		return c.json({ success: errors.length === 0, refreshed, errors });
	});

	app.post('/oauth/:provider/start', async (c) => {
		const provider = c.req.param('provider') as ProviderType;
		const validProviders = authManager.getOAuthProviders();
		if (!validProviders.includes(provider)) {
			return c.json({ error: `Invalid OAuth provider: ${provider}` }, 400);
		}
		try {
			const result = await authManager.startOAuth(provider);
			return c.json({ auth_url: result.url, state: result.state, incognito: result.incognito });
		} catch (err) {
			const message = err instanceof Error ? err.message : 'Unknown error';
			return c.json({ error: message }, 500);
		}
	});

	app.get('/oauth/:provider/poll', async (c) => {
		const provider = c.req.param('provider') as ProviderType;
		const state = c.req.query('state');
		if (!state) {
			return c.json({ error: 'Missing state parameter' }, 400);
		}
		const validProviders = authManager.getOAuthProviders();
		if (!validProviders.includes(provider)) {
			return c.json({ error: `Invalid OAuth provider: ${provider}` }, 400);
		}
		const result = await authManager.getOAuthStatus(state);
		if (result.error) {
			return c.json({ status: 'error', error: result.error });
		}
		if (result.completed && result.authFile) {
			return c.json({
				status: 'completed',
				provider: result.authFile.provider,
				email: result.authFile.email,
			});
		}
		return c.json({ status: 'pending' });
	});

	app.post('/oauth/:provider/cancel', async (c) => {
		const body = (await c.req.json().catch(() => ({
			state: undefined,
		}))) as { state?: string };
		const state = body.state;
		if (!state) {
			return c.json({ error: 'Missing state' }, 400);
		}
		await store.deletePendingSession(state);
		return c.json({ success: true });
	});

	app.post('/device-code/:provider/start', async (c) => {
		const provider = c.req.param('provider');
		if (provider === 'kiro-aws') {
			const result = await startKiroAwsDeviceCode(store);
			if (!result.success) {
				return c.json({ error: result.error || 'Failed to start device code flow' }, 500);
			}
			return c.json({
				device_code: result.deviceCode,
				user_code: result.userCode,
				verification_uri: result.verificationUri,
				expires_in: result.expiresIn,
			});
		}

		const validProviders = authManager.getDeviceCodeProviders();
		if (!validProviders.includes(provider as ProviderType)) {
			return c.json({ error: `Invalid device code provider: ${provider}` }, 400);
		}
		try {
			const result = await authManager.startDeviceFlow(provider as ProviderType);
			return c.json({
				device_code: result.deviceCode,
				user_code: result.userCode,
				verification_uri: result.verificationUri,
				expires_in: result.expiresIn,
				interval: result.interval,
			});
		} catch (err) {
			const message = err instanceof Error ? err.message : 'Unknown error';
			return c.json({ error: message }, 500);
		}
	});

	app.get('/device-code/:provider/poll', async (c) => {
		const provider = c.req.param('provider');
		const deviceCode = c.req.query('device_code');
		if (!deviceCode) {
			return c.json({ error: 'Missing device_code' }, 400);
		}
		if (provider === 'kiro-aws') {
			const result = await pollKiroAwsDeviceCode(store, deviceCode);
			if (result.status === 'success') {
				return c.json({ status: 'completed', provider: 'kiro', email: result.email });
			}
			if (result.status === 'error') {
				return c.json({ status: 'error', error: result.error });
			}
			return c.json({ status: 'pending' });
		}

		const validProviders = authManager.getDeviceCodeProviders();
		if (!validProviders.includes(provider as ProviderType)) {
			return c.json({ error: `Invalid device code provider: ${provider}` }, 400);
		}
		const result = await authManager.pollDeviceCode(provider as ProviderType, deviceCode);
		if (result.status === 'completed' && result.authFile) {
			return c.json({
				status: 'completed',
				provider: result.authFile.provider,
				email: result.authFile.email,
			});
		}
		if (result.status === 'error') {
			return c.json({ status: 'error', error: result.error });
		}
		if (result.status === 'expired') {
			return c.json({ status: 'expired', error: result.error });
		}
		return c.json({ status: 'pending' });
	});

	app.post('/device-code/:provider/cancel', async (c) => {
		const body = (await c.req.json().catch(() => ({
			device_code: undefined,
		}))) as { device_code?: string };
		const deviceCode = body.device_code;
		if (!deviceCode) {
			return c.json({ error: 'Missing device_code' }, 400);
		}
		await store.deletePendingSession(deviceCode);
		return c.json({ success: true });
	});

	return app;
}
