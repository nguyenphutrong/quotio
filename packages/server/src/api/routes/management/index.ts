/**
 * Management API routes
 *
 * Endpoints for server administration and monitoring.
 */
import { Hono } from 'hono';
import type { AuthManager } from '../../../auth/index.js';
import type { MetricsRegistry, RequestLogger } from '../../../logging/index.js';
import type { TokenStore } from '../../../store/index.js';
import { healthRoutes } from './health.js';
import { logsRoutes } from './logs.js';
import { oauthManagementRoutes } from './oauth.js';
import { usageRoutes } from './usage.js';

interface ManagementRoutesDeps {
	authManager: AuthManager;
	store: TokenStore;
	metrics: MetricsRegistry;
	logger: RequestLogger;
}

export function managementRoutes(deps: ManagementRoutesDeps): Hono {
	const app = new Hono();
	const { authManager, store, metrics, logger } = deps;

	// Mount health routes at /
	app.route('/', healthRoutes());

	// Mount OAuth management routes
	app.route('/', oauthManagementRoutes({ authManager }));

	// Mount usage routes
	app.route('/usage', usageRoutes({ metrics, store }));

	// Mount logs routes
	app.route('/logs', logsRoutes({ logger }));

	return app;
}
