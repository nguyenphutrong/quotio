/**
 * HTTP Server for cross-platform IPC (Windows, Linux, macOS).
 * JSON-RPC 2.0 over HTTP as alternative to Unix sockets.
 * Port: 18318 (configurable via QUOTIO_HTTP_PORT env var)
 */

import { logger } from '../utils/logger.ts';
import {
	ErrorCodes,
	type JsonRpcErrorResponse,
	type JsonRpcRequest,
	type JsonRpcResponse,
	createErrorResponse,
	createSuccessResponse,
	parseRequest,
} from './protocol.ts';

export const HTTP_IPC_PORT = Number.parseInt(process.env.QUOTIO_HTTP_PORT ?? '18318', 10);
export const HTTP_IPC_HOST = '127.0.0.1';

export type MethodHandler = (params: unknown) => Promise<unknown>;

interface HTTPServerState {
	running: boolean;
	server: ReturnType<typeof Bun.serve> | null;
	port: number;
	handlers: Map<string, MethodHandler>;
}

const state: HTTPServerState = {
	running: false,
	server: null,
	port: HTTP_IPC_PORT,
	handlers: new Map(),
};

export function registerHTTPHandler(method: string, handler: MethodHandler): void {
	state.handlers.set(method, handler);
}

export function registerHTTPHandlers(handlers: Record<string, MethodHandler>): void {
	for (const [method, handler] of Object.entries(handlers)) {
		state.handlers.set(method, handler);
	}
}

export function setHTTPHandlers(handlers: Map<string, MethodHandler>): void {
	state.handlers = handlers;
}

function isJsonRpcErrorResponse(obj: unknown): obj is JsonRpcErrorResponse {
	return typeof obj === 'object' && obj !== null && 'error' in obj;
}

async function handleRPCRequest(request: JsonRpcRequest): Promise<JsonRpcResponse> {
	const handler = state.handlers.get(request.method);

	if (!handler) {
		return createErrorResponse(
			request.id,
			ErrorCodes.METHOD_NOT_FOUND,
			`Method not found: ${request.method}`,
		);
	}

	try {
		const result = await handler(request.params ?? {});
		return createSuccessResponse(request.id, result);
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		logger.error(`HTTP RPC handler error for ${request.method}: ${message}`);
		return createErrorResponse(request.id, ErrorCodes.INTERNAL_ERROR, message);
	}
}

async function processRPCBody(body: string): Promise<JsonRpcResponse> {
	const parsed = parseRequest(body);

	if (isJsonRpcErrorResponse(parsed)) {
		return parsed;
	}

	return handleRPCRequest(parsed);
}

function getVersion(): string {
	try {
		const pkg = require('../../package.json');
		return pkg.version ?? '0.0.0';
	} catch {
		return '0.0.0';
	}
}

export async function startHTTPServer(options?: {
	port?: number;
	host?: string;
}): Promise<void> {
	if (state.running) {
		throw new Error('HTTP IPC server is already running');
	}

	const port = options?.port ?? HTTP_IPC_PORT;
	const host = options?.host ?? HTTP_IPC_HOST;

	state.server = Bun.serve({
		port,
		hostname: host,

		async fetch(req) {
			const url = new URL(req.url);

			const corsHeaders = {
				'Access-Control-Allow-Origin': '*',
				'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
				'Access-Control-Allow-Headers': 'Content-Type',
			};

			if (req.method === 'OPTIONS') {
				return new Response(null, { status: 204, headers: corsHeaders });
			}

			if (url.pathname === '/health' && req.method === 'GET') {
				return Response.json(
					{ status: 'ok', version: getVersion(), timestamp: Date.now() },
					{ headers: corsHeaders },
				);
			}

			if (url.pathname === '/version' && req.method === 'GET') {
				return Response.json({ version: getVersion() }, { headers: corsHeaders });
			}

			if (url.pathname === '/rpc' && req.method === 'POST') {
				try {
					const body = await req.text();
					const response = await processRPCBody(body);

					return Response.json(response, {
						headers: { ...corsHeaders, 'Content-Type': 'application/json' },
					});
				} catch (error) {
					const message = error instanceof Error ? error.message : String(error);
					return Response.json(createErrorResponse(null, ErrorCodes.INTERNAL_ERROR, message), {
						status: 500,
						headers: corsHeaders,
					});
				}
			}

			return Response.json(
				{ error: 'Not found', path: url.pathname },
				{ status: 404, headers: corsHeaders },
			);
		},

		error(error) {
			logger.error(`HTTP IPC server error: ${error.message}`);
			return Response.json({ error: 'Internal server error' }, { status: 500 });
		},
	});

	state.running = true;
	state.port = port;

	logger.info(`HTTP IPC server listening on http://${host}:${port}`);
}

export async function stopHTTPServer(): Promise<void> {
	if (!state.running || !state.server) {
		return;
	}

	state.server.stop();
	state.server = null;
	state.running = false;

	logger.info('HTTP IPC server stopped');
}

export function isHTTPServerRunning(): boolean {
	return state.running;
}

export function getHTTPServerPort(): number | null {
	return state.running ? state.port : null;
}
