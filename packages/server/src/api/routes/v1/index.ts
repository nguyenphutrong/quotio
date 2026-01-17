/**
 * v1 API routes
 *
 * OpenAI-compatible API endpoints.
 */
import { Hono } from 'hono';
import { stream } from 'hono/streaming';
import type { ProxyDispatcher } from '../../../proxy/index.js';
import {
	ChatCompletionRequestSchema,
	ClaudeMessageRequestSchema,
	inferProviderFromModel,
} from '../../../proxy/index.js';
import { modelsRoutes } from './models.js';

export interface V1RoutesConfig {
	dispatcher: ProxyDispatcher;
}

export function v1Routes(config: V1RoutesConfig): Hono {
	const app = new Hono();
	const { dispatcher } = config;

	// Mount models routes
	app.route('/', modelsRoutes());

	// OpenAI-compatible chat completions
	app.post('/chat/completions', async (c) => {
		try {
			const body = await c.req.json();
			const parsed = ChatCompletionRequestSchema.safeParse(body);

			if (!parsed.success) {
				return c.json(
					{
						error: {
							message: 'Invalid request body',
							type: 'invalid_request_error',
							code: 'invalid_body',
							details: parsed.error.flatten(),
						},
					},
					400,
				);
			}

			const request = parsed.data;
			const isStream = request.stream === true;

			// Infer provider from model
			const provider = inferProviderFromModel(request.model);
			const providers = provider ? [provider] : [];

			// Build proxy request
			const proxyRequest = {
				model: request.model,
				providers,
				payload: new TextEncoder().encode(JSON.stringify(request)),
				stream: isStream,
				metadata: {},
			};

			if (isStream) {
				// Streaming response
				return stream(c, async (stream) => {
					c.header('Content-Type', 'text/event-stream');
					c.header('Cache-Control', 'no-cache');
					c.header('Connection', 'keep-alive');

					try {
						for await (const chunk of dispatcher.dispatchStreamWithFallback(proxyRequest)) {
							if (chunk.error) {
								const errorData = JSON.stringify({
									error: { message: chunk.error.message },
								});
								await stream.write(`data: ${errorData}\n\n`);
								break;
							}

							if (chunk.done) {
								await stream.write('data: [DONE]\n\n');
								break;
							}

							const text = new TextDecoder().decode(chunk.payload);
							if (text.trim()) {
								await stream.write(text);
							}
						}
					} catch (err) {
						const errorMsg = err instanceof Error ? err.message : 'Unknown error';
						await stream.write(`data: ${JSON.stringify({ error: { message: errorMsg } })}\n\n`);
					}
				});
			}

			// Non-streaming response
			const result = await dispatcher.dispatchWithFallback(proxyRequest);
			const responseText = new TextDecoder().decode(result.payload);

			try {
				const jsonResponse = JSON.parse(responseText);
				return c.json(jsonResponse);
			} catch {
				// If not JSON, return raw response
				return c.text(responseText);
			}
		} catch (err) {
			const message = err instanceof Error ? err.message : 'Unknown error';
			return c.json(
				{
					error: {
						message,
						type: 'server_error',
						code: 'internal_error',
					},
				},
				500,
			);
		}
	});

	// Claude-compatible messages API
	app.post('/messages', async (c) => {
		try {
			const body = await c.req.json();
			const parsed = ClaudeMessageRequestSchema.safeParse(body);

			if (!parsed.success) {
				return c.json(
					{
						error: {
							message: 'Invalid request body',
							type: 'invalid_request_error',
							code: 'invalid_body',
							details: parsed.error.flatten(),
						},
					},
					400,
				);
			}

			const request = parsed.data;
			const isStream = request.stream === true;

			// Claude messages always use claude provider
			const proxyRequest = {
				model: request.model,
				providers: ['claude'],
				payload: new TextEncoder().encode(JSON.stringify(request)),
				stream: isStream,
				metadata: {},
			};

			if (isStream) {
				// Streaming response
				return stream(c, async (stream) => {
					c.header('Content-Type', 'text/event-stream');
					c.header('Cache-Control', 'no-cache');
					c.header('Connection', 'keep-alive');

					try {
						for await (const chunk of dispatcher.dispatchStreamWithFallback(proxyRequest)) {
							if (chunk.error) {
								const errorData = JSON.stringify({
									type: 'error',
									error: { message: chunk.error.message },
								});
								await stream.write(`event: error\ndata: ${errorData}\n\n`);
								break;
							}

							if (chunk.done) {
								await stream.write('event: message_stop\ndata: {}\n\n');
								break;
							}

							const text = new TextDecoder().decode(chunk.payload);
							if (text.trim()) {
								await stream.write(text);
							}
						}
					} catch (err) {
						const errorMsg = err instanceof Error ? err.message : 'Unknown error';
						await stream.write(
							`event: error\ndata: ${JSON.stringify({ type: 'error', error: { message: errorMsg } })}\n\n`,
						);
					}
				});
			}

			// Non-streaming response
			const result = await dispatcher.dispatchWithFallback(proxyRequest);
			const responseText = new TextDecoder().decode(result.payload);

			try {
				const jsonResponse = JSON.parse(responseText);
				return c.json(jsonResponse);
			} catch {
				return c.text(responseText);
			}
		} catch (err) {
			const message = err instanceof Error ? err.message : 'Unknown error';
			return c.json(
				{
					error: {
						type: 'server_error',
						message,
					},
				},
				500,
			);
		}
	});

	return app;
}
