import { Hono } from 'hono';

export function healthRoutes(): Hono {
	const app = new Hono();

	app.get('/health', async (c) => {
		return c.json({
			status: 'ok',
			version: '0.1.0',
			timestamp: new Date().toISOString(),
			services: {
				server: 'ok',
			},
		});
	});

	app.get('/ready', async (c) => {
		return c.json({ ready: true });
	});

	app.get('/live', (c) => {
		return c.json({ alive: true });
	});

	return app;
}
