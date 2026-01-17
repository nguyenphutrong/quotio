/**
 * API Routes - Management API for cross-platform clients
 *
 * All routes are prefixed with /api
 * This replaces the daemon IPC methods with HTTP endpoints.
 */
import { Hono } from 'hono';
import type { AuthManager } from '../../../auth/index.js';
import type { Config } from '../../../config/index.js';
import type { MetricsRegistry, RequestLogger } from '../../../logging/index.js';
import type { TokenStore } from '../../../store/index.js';
import { authRoutes } from './auth.js';
import { lifecycleRoutes } from './lifecycle.js';

export interface ApiRoutesDeps {
	config: Config;
	authManager: AuthManager;
	store: TokenStore;
	metrics: MetricsRegistry;
	logger: RequestLogger;
}

export function apiRoutes(deps: ApiRoutesDeps): Hono {
	const app = new Hono();
	const { config } = deps;

	// Mount lifecycle routes (/api/health, /api/status, /api/proxy/*)
	app.route('/', lifecycleRoutes({ config }));

	// Auth routes (/api/auth, /api/oauth, /api/device-code)
	app.route('/', authRoutes({ authManager: deps.authManager, store: deps.store }));

	// Future routes will be mounted here:
	// app.route('/', quotaRoutes({ store }));                   // QUO-39
	// app.route('/', agentRoutes({ ... }));                     // QUO-40
	// app.route('/', configRoutes({ config }));                 // QUO-41
	// app.route('/', fallbackRoutes({ ... }));                  // QUO-42
	// app.route('/', statsRoutes({ metrics, logger }));         // QUO-43
	// app.route('/', apiKeysRoutes({ store }));                 // QUO-44

	return app;
}
