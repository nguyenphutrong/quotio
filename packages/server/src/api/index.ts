import { Hono } from 'hono';
import type { AuthManager } from '../auth/index.js';
import type { Config } from '../config/index.js';
import { MetricsRegistry, RequestLogger } from '../logging/index.js';
import type { ProxyDispatcher } from '../proxy/index.js';
import type { TokenStore } from '../store/index.js';
import { corsMiddleware } from './middleware/cors.js';
import { loggingMiddleware } from './middleware/logging.js';
import { managementRoutes } from './routes/management/index.js';
import { oauthRoutes } from './routes/oauth/index.js';
import { v1Routes } from './routes/v1/index.js';

export interface AppDependencies {
	config: Config;
	authManager: AuthManager;
	store: TokenStore;
	dispatcher: ProxyDispatcher;
}

const globalMetrics = new MetricsRegistry();
const globalLogger = new RequestLogger({
	level: 'info',
	skipPaths: ['/health', '/healthz', '/ready', '/live'],
});

export function createApp(deps: AppDependencies): Hono {
	const app = new Hono();
	const { config, authManager, store, dispatcher } = deps;

	app.use('*', loggingMiddleware);
	app.use('*', corsMiddleware);
	app.use('*', globalLogger.middleware());

	app.get('/health', (c) => {
		return c.json({
			status: 'ok',
			version: '0.1.0',
			timestamp: new Date().toISOString(),
		});
	});

	app.get('/version', (c) => {
		return c.json({
			version: '0.1.0',
			runtime: 'bun',
			framework: 'hono',
		});
	});

	app.route('/', oauthRoutes({ authManager }));

	app.route('/v1', v1Routes({ dispatcher }));

	app.route(
		'/v0/management',
		managementRoutes({
			config,
			authManager,
			store,
			metrics: globalMetrics,
			logger: globalLogger,
		}),
	);

	app.notFound((c) => {
		return c.json(
			{
				error: {
					message: 'Not Found: ' + c.req.path,
					type: 'invalid_request_error',
					code: 'not_found',
				},
			},
			404,
		);
	});

	app.onError((err, c) => {
		console.error('[ERROR] ' + c.req.method + ' ' + c.req.path + ':', err);
		return c.json(
			{
				error: {
					message: err.message || 'Internal server error',
					type: 'server_error',
					code: 'internal_error',
				},
			},
			500,
		);
	});

	return app;
}

export { globalMetrics, globalLogger };
