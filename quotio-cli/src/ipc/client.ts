import { connect, type Socket } from "bun";
import { existsSync } from "node:fs";
import { ConfigFiles, getPlatform } from "../utils/paths.ts";
import {
  type JsonRpcResponse,
  type RequestId,
  type MethodName,
  type MethodParams,
  type MethodResult,
  ErrorCodes,
  createRequest,
  encodeMessage,
  createMessageParser,
  isErrorResponse,
  JSONRPC_VERSION,
} from "./protocol.ts";

export class IPCClientError extends Error {
  constructor(
    message: string,
    public readonly code?: number
  ) {
    super(message);
    this.name = "IPCClientError";
  }
}

interface PendingRequest {
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

interface IPCClientState {
  socket: Socket<{ parser: (chunk: Buffer | string) => void }> | null;
  connected: boolean;
  socketPath: string;
  pendingRequests: Map<RequestId, PendingRequest>;
  requestIdCounter: number;
  reconnecting: boolean;
}

const DEFAULT_TIMEOUT = 30000;

export class IPCClient {
  private state: IPCClientState = {
    socket: null,
    connected: false,
    socketPath: "",
    pendingRequests: new Map(),
    requestIdCounter: 0,
    reconnecting: false,
  };

  private readonly timeout: number;

  constructor(options?: { timeout?: number }) {
    this.timeout = options?.timeout ?? DEFAULT_TIMEOUT;
  }

  async connect(socketPath?: string): Promise<void> {
    if (this.state.connected) {
      return;
    }

    const path = socketPath ?? ConfigFiles.socket();
    this.state.socketPath = path;

    const platform = getPlatform();
    if (platform !== "win32" && !existsSync(path)) {
      throw new IPCClientError("Daemon socket not found. Is the daemon running?", ErrorCodes.DAEMON_NOT_RUNNING);
    }

    const self = this;

    this.state.socket = await connect<{ parser: (chunk: Buffer | string) => void }>({
      unix: path,
      socket: {
        open(socket) {
          socket.data = {
            parser: createMessageParser((msg) => self.handleMessage(msg)),
          };
          self.state.connected = true;
        },

        data(socket, buffer) {
          socket.data.parser(buffer);
        },

        close() {
          self.state.connected = false;
          self.state.socket = null;
          self.rejectAllPending("Connection closed");
        },

        error(_socket, error) {
          self.rejectAllPending(`Socket error: ${error.message}`);
        },
      },
    });

    await this.waitForConnection();
  }

  private waitForConnection(): Promise<void> {
    return new Promise((resolve, reject) => {
      const maxWait = 5000;
      const start = Date.now();

      const check = () => {
        if (this.state.connected) {
          resolve();
        } else if (Date.now() - start > maxWait) {
          reject(new IPCClientError("Connection timeout"));
        } else {
          setTimeout(check, 50);
        }
      };

      check();
    });
  }

  private handleMessage(rawMessage: string): void {
    let response: JsonRpcResponse;
    try {
      response = JSON.parse(rawMessage) as JsonRpcResponse;
    } catch {
      return;
    }

    if (response.id === null || response.id === undefined) {
      return;
    }

    const pending = this.state.pendingRequests.get(response.id);
    if (!pending) {
      return;
    }

    this.state.pendingRequests.delete(response.id);
    clearTimeout(pending.timer);

    if (isErrorResponse(response)) {
      pending.reject(new IPCClientError(response.error.message, response.error.code));
    } else {
      pending.resolve(response.result);
    }
  }

  private rejectAllPending(message: string): void {
    for (const [id, pending] of this.state.pendingRequests) {
      clearTimeout(pending.timer);
      pending.reject(new IPCClientError(message));
      this.state.pendingRequests.delete(id);
    }
  }

  async call<M extends MethodName>(method: M, params?: MethodParams<M>): Promise<MethodResult<M>> {
    if (!this.state.connected || !this.state.socket) {
      throw new IPCClientError("Not connected to daemon");
    }

    const id = ++this.state.requestIdCounter;
    const request = createRequest(id, method, params);

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.state.pendingRequests.delete(id);
        reject(new IPCClientError(`Request timeout for ${method}`));
      }, this.timeout);

      this.state.pendingRequests.set(id, {
        resolve: resolve as (result: unknown) => void,
        reject,
        timer,
      });

      try {
        const socket = this.state.socket;
        if (socket) {
          socket.write(encodeMessage(request));
        } else {
          throw new Error("Socket not available");
        }
      } catch (error) {
        this.state.pendingRequests.delete(id);
        clearTimeout(timer);
        reject(new IPCClientError(error instanceof Error ? error.message : "Failed to send request"));
      }
    });
  }

  disconnect(): void {
    if (this.state.socket) {
      try {
        this.state.socket.end();
      } catch {}
    }
    this.state.socket = null;
    this.state.connected = false;
    this.rejectAllPending("Disconnected");
  }

  isConnected(): boolean {
    return this.state.connected;
  }
}

let sharedClient: IPCClient | null = null;

export function getSharedClient(): IPCClient {
  if (!sharedClient) {
    sharedClient = new IPCClient();
  }
  return sharedClient;
}

export async function isDaemonRunning(): Promise<boolean> {
  const socketPath = ConfigFiles.socket();
  const platform = getPlatform();

  if (platform !== "win32" && !existsSync(socketPath)) {
    return false;
  }

  const client = new IPCClient({ timeout: 2000 });
  try {
    await client.connect(socketPath);
    const response = await client.call("daemon.ping", {});
    client.disconnect();
    return response.pong === true;
  } catch {
    client.disconnect();
    return false;
  }
}

export async function sendCommand<M extends MethodName>(
  method: M,
  params?: MethodParams<M>
): Promise<MethodResult<M>> {
  const client = new IPCClient();
  try {
    await client.connect();
    const result = await client.call(method, params);
    client.disconnect();
    return result;
  } catch (error) {
    client.disconnect();
    throw error;
  }
}
