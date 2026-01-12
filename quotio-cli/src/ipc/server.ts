import type { Socket } from "bun";
import { existsSync, unlinkSync, chmodSync } from "node:fs";
import { dirname } from "node:path";
import { mkdir } from "node:fs/promises";
import { ConfigFiles, getPlatform } from "../utils/paths.ts";
import { logger } from "../utils/logger.ts";
import {
  type JsonRpcRequest,
  type JsonRpcResponse,
  type JsonRpcErrorResponse,
  ErrorCodes,
  parseRequest,
  createSuccessResponse,
  createErrorResponse,
  encodeMessage,
  createMessageParser,
} from "./protocol.ts";

export type MethodHandler = (params: unknown) => Promise<unknown>;

interface ClientConnection {
  socket: Socket<{ parser: (chunk: Buffer | string) => void }>;
  connectedAt: Date;
}

interface IPCServerState {
  running: boolean;
  socketPath: string;
  connections: Map<number, ClientConnection>;
  handlers: Map<string, MethodHandler>;
  server: ReturnType<typeof Bun.listen> | null;
}

const state: IPCServerState = {
  running: false,
  socketPath: "",
  connections: new Map(),
  handlers: new Map(),
  server: null,
};

let connectionIdCounter = 0;

export function registerHandler(method: string, handler: MethodHandler): void {
  state.handlers.set(method, handler);
}

export function registerHandlers(handlers: Record<string, MethodHandler>): void {
  for (const [method, handler] of Object.entries(handlers)) {
    state.handlers.set(method, handler);
  }
}

async function handleRequest(request: JsonRpcRequest): Promise<JsonRpcResponse> {
  const handler = state.handlers.get(request.method);

  if (!handler) {
    return createErrorResponse(
      request.id,
      ErrorCodes.METHOD_NOT_FOUND,
      `Method not found: ${request.method}`
    );
  }

  try {
    const result = await handler(request.params ?? {});
    return createSuccessResponse(request.id, result);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    logger.error(`Handler error for ${request.method}: ${message}`);
    return createErrorResponse(request.id, ErrorCodes.INTERNAL_ERROR, message);
  }
}

function isJsonRpcErrorResponse(obj: unknown): obj is JsonRpcErrorResponse {
  return typeof obj === "object" && obj !== null && "error" in obj;
}

function processMessage(
  socket: Socket<{ parser: (chunk: Buffer | string) => void }>,
  rawMessage: string
): void {
  const parsed = parseRequest(rawMessage);

  if (isJsonRpcErrorResponse(parsed)) {
    socket.write(encodeMessage(parsed));
    return;
  }

  handleRequest(parsed)
    .then((response) => {
      socket.write(encodeMessage(response));
    })
    .catch((error) => {
      const message = error instanceof Error ? error.message : String(error);
      socket.write(
        encodeMessage(createErrorResponse(parsed.id, ErrorCodes.INTERNAL_ERROR, message))
      );
    });
}

export async function startServer(socketPath?: string): Promise<void> {
  if (state.running) {
    throw new Error("IPC server is already running");
  }

  const path = socketPath ?? ConfigFiles.socket();
  const platform = getPlatform();

  state.socketPath = path;

  if (platform !== "win32") {
    const socketDir = dirname(path);
    await mkdir(socketDir, { recursive: true });

    if (existsSync(path)) {
      try {
        unlinkSync(path);
      } catch {
        throw new Error(`Cannot remove existing socket at ${path}`);
      }
    }
  }

  state.server = Bun.listen<{ parser: (chunk: Buffer | string) => void }>({
    unix: state.socketPath,
    socket: {
      open(socket) {
        const connId = ++connectionIdCounter;
        const parser = createMessageParser((msg) => processMessage(socket, msg));
        socket.data = { parser };

        state.connections.set(connId, {
          socket,
          connectedAt: new Date(),
        });

        logger.debug("IPC client connected", { connId });
      },

      data(socket, buffer) {
        socket.data.parser(buffer);
      },

      close(socket) {
        for (const [id, conn] of state.connections) {
          if (conn.socket === socket) {
            state.connections.delete(id);
            logger.debug("IPC client disconnected", { connId: id });
            break;
          }
        }
      },

      error(_socket, error) {
        logger.error(`IPC socket error: ${error.message}`);
      },
    },
  });

  if (platform !== "win32") {
    try {
      chmodSync(state.socketPath, 0o600);
    } catch {
      logger.warn("Could not set socket permissions");
    }
  }

  state.running = true;
  logger.info(`IPC server listening on ${state.socketPath}`);
}

export async function stopServer(): Promise<void> {
  if (!state.running || !state.server) {
    return;
  }

  for (const [, conn] of state.connections) {
    try {
      conn.socket.end();
    } catch {}
  }
  state.connections.clear();

  state.server.stop();
  state.server = null;

  const platform = getPlatform();
  if (platform !== "win32" && existsSync(state.socketPath)) {
    try {
      unlinkSync(state.socketPath);
    } catch {}
  }

  state.running = false;
  logger.info("IPC server stopped");
}

export function isServerRunning(): boolean {
  return state.running;
}

export function getSocketPath(): string {
  return state.socketPath;
}

export function getConnectionCount(): number {
  return state.connections.size;
}

export function broadcast(response: JsonRpcResponse): void {
  const message = encodeMessage(response);
  for (const [, conn] of state.connections) {
    try {
      conn.socket.write(message);
    } catch {}
  }
}
