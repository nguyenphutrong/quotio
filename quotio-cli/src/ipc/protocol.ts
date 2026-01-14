/**
 * IPC Protocol definitions for quotio-cli daemon communication.
 * Implements JSON-RPC 2.0 specification over Unix sockets / Windows named pipes.
 *
 * @see https://www.jsonrpc.org/specification
 */

// ============================================================================
// JSON-RPC 2.0 Base Types
// ============================================================================

/** JSON-RPC 2.0 version identifier */
export const JSONRPC_VERSION = "2.0" as const;

/** Valid JSON-RPC request ID types */
export type RequestId = string | number;

/** JSON-RPC 2.0 Request object */
export interface JsonRpcRequest<P = unknown> {
	jsonrpc: typeof JSONRPC_VERSION;
	id: RequestId;
	method: string;
	params?: P;
}

/** JSON-RPC 2.0 Notification (no id, no response expected) */
export interface JsonRpcNotification<P = unknown> {
	jsonrpc: typeof JSONRPC_VERSION;
	method: string;
	params?: P;
}

/** JSON-RPC 2.0 Success Response */
export interface JsonRpcSuccessResponse<R = unknown> {
	jsonrpc: typeof JSONRPC_VERSION;
	id: RequestId;
	result: R;
}

/** JSON-RPC 2.0 Error object */
export interface JsonRpcErrorObject {
	/** Error code (integer) */
	code: number;
	/** Human-readable error message */
	message: string;
	/** Optional additional error data */
	data?: unknown;
}

/** JSON-RPC 2.0 Error Response */
export interface JsonRpcErrorResponse {
	jsonrpc: typeof JSONRPC_VERSION;
	id: RequestId | null;
	error: JsonRpcErrorObject;
}

/** JSON-RPC 2.0 Response (success or error) */
export type JsonRpcResponse<R = unknown> =
	| JsonRpcSuccessResponse<R>
	| JsonRpcErrorResponse;

// ============================================================================
// Standard JSON-RPC 2.0 Error Codes
// ============================================================================

export const ErrorCodes = {
	/** Invalid JSON was received */
	PARSE_ERROR: -32700,
	/** The JSON sent is not a valid Request object */
	INVALID_REQUEST: -32600,
	/** The method does not exist / is not available */
	METHOD_NOT_FOUND: -32601,
	/** Invalid method parameter(s) */
	INVALID_PARAMS: -32602,
	/** Internal JSON-RPC error */
	INTERNAL_ERROR: -32603,
	// Application-specific error codes (must be outside -32000 to -32099)
	/** Proxy not running */
	PROXY_NOT_RUNNING: 1001,
	/** Authentication failed */
	AUTH_FAILED: 1002,
	/** Provider not found */
	PROVIDER_NOT_FOUND: 1003,
	/** Agent not found */
	AGENT_NOT_FOUND: 1004,
	/** Configuration error */
	CONFIG_ERROR: 1005,
	/** Daemon already running */
	DAEMON_ALREADY_RUNNING: 1006,
	/** Daemon not running */
	DAEMON_NOT_RUNNING: 1007,
} as const;

// ============================================================================
// IPC Method Definitions
// ============================================================================

/**
 * Available IPC methods and their parameter/result types.
 * This serves as the contract between client and server.
 */
export interface IPCMethods {
	// -------------------------------------------------------------------------
	// Daemon lifecycle
	// -------------------------------------------------------------------------
	"daemon.ping": {
		params: Record<string, never>;
		result: { pong: true; timestamp: number };
	};
	"daemon.status": {
		params: Record<string, never>;
		result: DaemonStatus;
	};
	"daemon.shutdown": {
		params: { graceful?: boolean };
		result: { success: true };
	};

	// -------------------------------------------------------------------------
	// Quota operations
	// -------------------------------------------------------------------------
	"quota.fetch": {
		params: { provider?: string; forceRefresh?: boolean };
		result: QuotaFetchResult;
	};
	"quota.list": {
		params: Record<string, never>;
		result: QuotaListResult;
	};

	// -------------------------------------------------------------------------
	// Agent operations
	// -------------------------------------------------------------------------
	"agent.detect": {
		params: { forceRefresh?: boolean };
		result: AgentDetectResult;
	};
	"agent.configure": {
		params: { agent: string; mode: "auto" | "manual" };
		result: AgentConfigureResult;
	};

	// -------------------------------------------------------------------------
	// Proxy operations
	// -------------------------------------------------------------------------
	"proxy.start": {
		params: { port?: number };
		result: ProxyStartResult;
	};
	"proxy.stop": {
		params: Record<string, never>;
		result: { success: true };
	};
	"proxy.status": {
		params: Record<string, never>;
		result: ProxyStatusResult;
	};
	"proxy.health": {
		params: Record<string, never>;
		result: { healthy: boolean };
	};

	// -------------------------------------------------------------------------
	// Auth operations
	// -------------------------------------------------------------------------
	"auth.list": {
		params: { provider?: string };
		result: AuthListResult;
	};

	// -------------------------------------------------------------------------
	// Config operations
	// -------------------------------------------------------------------------
	"config.get": {
		params: { key: string };
		result: { value: unknown };
	};
	"config.set": {
		params: { key: string; value: unknown };
		result: { success: true };
	};

	// -------------------------------------------------------------------------
	// Universal Provider operations
	// -------------------------------------------------------------------------
	"universal.list": {
		params: Record<string, never>;
		result: UniversalProviderListResult;
	};
	"universal.get": {
		params: { id: string };
		result: { provider: UniversalProviderInfo | null };
	};
	"universal.add": {
		params: UniversalProviderAddParams;
		result: { success: boolean; provider?: UniversalProviderInfo };
	};
	"universal.update": {
		params: UniversalProviderUpdateParams;
		result: { success: boolean; provider?: UniversalProviderInfo };
	};
	"universal.delete": {
		params: { id: string };
		result: { success: boolean };
	};
	"universal.setActive": {
		params: { agentId: string; providerId: string };
		result: { success: true };
	};
	"universal.getActive": {
		params: { agentId: string };
		result: { provider: UniversalProviderInfo | null };
	};
	"universal.storeKey": {
		params: { providerId: string; apiKey: string };
		result: { success: boolean; error?: string };
	};
	"universal.hasKey": {
		params: { providerId: string };
		result: { hasKey: boolean };
	};

	"oauth.start": {
		params: { provider: string; projectId?: string };
		result: OAuthStartResult;
	};
	"oauth.poll": {
		params: { state: string };
		result: OAuthPollResult;
	};

	// -------------------------------------------------------------------------
	// Request tracking operations
	// -------------------------------------------------------------------------
	"stats.list": {
		params: { provider?: string; minutes?: number };
		result: StatsListResult;
	};
	"stats.get": {
		params: Record<string, never>;
		result: StatsGetResult;
	};
	"stats.add": {
		params: StatsAddParams;
		result: { success: true };
	};
	"stats.clear": {
		params: Record<string, never>;
		result: { success: true };
	};
	"stats.status": {
		params: Record<string, never>;
		result: { isActive: boolean; entryCount: number };
	};

	// -------------------------------------------------------------------------
	// Tunnel operations (Cloudflare Tunnel)
	// -------------------------------------------------------------------------
	"tunnel.start": {
		params: { port: number };
		result: TunnelStartResult;
	};
	"tunnel.stop": {
		params: Record<string, never>;
		result: { success: true };
	};
	"tunnel.status": {
		params: Record<string, never>;
		result: TunnelStatusResult;
	};
	"tunnel.installation": {
		params: Record<string, never>;
		result: TunnelInstallationResult;
	};

	// -------------------------------------------------------------------------
	// Fallback / Virtual Model operations
	// -------------------------------------------------------------------------
	"fallback.getConfig": {
		params: Record<string, never>;
		result: FallbackConfigResult;
	};
	"fallback.setEnabled": {
		params: { enabled: boolean };
		result: { success: true };
	};
	"fallback.listModels": {
		params: Record<string, never>;
		result: FallbackListModelsResult;
	};
	"fallback.getModel": {
		params: { id: string };
		result: { model: VirtualModelInfo | null };
	};
	"fallback.addModel": {
		params: { name: string };
		result: { success: boolean; model?: VirtualModelInfo };
	};
	"fallback.removeModel": {
		params: { id: string };
		result: { success: boolean };
	};
	"fallback.updateModel": {
		params: VirtualModelUpdateParams;
		result: { success: boolean };
	};
	"fallback.addEntry": {
		params: { modelId: string; provider: string; modelName: string };
		result: { success: boolean; entry?: FallbackEntryInfo };
	};
	"fallback.removeEntry": {
		params: { modelId: string; entryId: string };
		result: { success: boolean };
	};
	"fallback.moveEntry": {
		params: { modelId: string; fromIndex: number; toIndex: number };
		result: { success: boolean };
	};
	"fallback.getRouteStates": {
		params: Record<string, never>;
		result: FallbackRouteStatesResult;
	};
	"fallback.clearRouteStates": {
		params: Record<string, never>;
		result: { success: true };
	};
	"fallback.export": {
		params: Record<string, never>;
		result: { json: string };
	};
	"fallback.import": {
		params: { json: string };
		result: { success: boolean };
	};

	"proxyConfig.getAll": {
		params: Record<string, never>;
		result: ProxyConfigGetAllResult;
	};
	"proxyConfig.get": {
		params: { key: string };
		result: ProxyConfigGetResult;
	};
	"proxyConfig.set": {
		params: { key: string; value: unknown };
		result: { success: boolean; error?: string };
	};

	"auth.delete": {
		params: { name: string };
		result: { success: boolean; error?: string };
	};
	"auth.deleteAll": {
		params: Record<string, never>;
		result: { success: boolean; error?: string };
	};
	"auth.setDisabled": {
		params: { name: string; disabled: boolean };
		result: { success: boolean; error?: string };
	};
	"auth.models": {
		params: { name: string };
		result: AuthModelsResult;
	};

	"apiKeys.list": {
		params: Record<string, never>;
		result: APIKeysListResult;
	};
	"apiKeys.add": {
		params: Record<string, never>;
		result: { success: boolean; key?: string; error?: string };
	};
	"apiKeys.delete": {
		params: { key: string };
		result: { success: boolean; error?: string };
	};

	"proxy.healthCheck": {
		params: Record<string, never>;
		result: { healthy: boolean; error?: string };
	};

	"logs.fetch": {
		params: { after?: number };
		result: LogsFetchResult;
	};
	"logs.clear": {
		params: Record<string, never>;
		result: { success: boolean; error?: string };
	};

	"proxy.latestVersion": {
		params: Record<string, never>;
		result: ProxyLatestVersionResult;
	};
}

/** All available method names */
export type MethodName = keyof IPCMethods;

/** Extract params type for a method */
export type MethodParams<M extends MethodName> = IPCMethods[M]["params"];

/** Extract result type for a method */
export type MethodResult<M extends MethodName> = IPCMethods[M]["result"];

// ============================================================================
// Result Types
// ============================================================================

export interface DaemonStatus {
	running: true;
	pid: number;
	startedAt: string;
	uptime: number;
	proxyRunning: boolean;
	proxyPort: number | null;
	version: string;
}

export interface QuotaFetchResult {
	success: boolean;
	quotas: ProviderQuotaInfo[];
	errors?: { provider: string; error: string }[];
}

export interface ProviderQuotaInfo {
	provider: string;
	email: string;
	models: ModelQuotaInfo[];
	lastUpdated: string;
	isForbidden: boolean;
}

export interface ModelQuotaInfo {
	name: string;
	percentage: number;
	resetTime: string;
	used?: number;
	limit?: number;
}

export interface QuotaListResult {
	quotas: ProviderQuotaInfo[];
	lastFetched: string | null;
}

export interface AgentDetectResult {
	agents: DetectedAgent[];
}

export interface DetectedAgent {
	id: string;
	name: string;
	installed: boolean;
	configured: boolean;
	binaryPath: string | null;
	version: string | null;
}

export interface AgentConfigureResult {
	success: boolean;
	agent: string;
	configPath: string | null;
	backupPath: string | null;
}

export interface ProxyStartResult {
	success: boolean;
	port: number;
	pid: number;
}

export interface ProxyStatusResult {
	running: boolean;
	port: number | null;
	pid: number | null;
	startedAt: string | null;
	healthy: boolean;
}

export interface ProxyLatestVersionResult {
	success: boolean;
	latestVersion?: string;
	error?: string;
}

export interface AuthListResult {
	accounts: AuthAccount[];
}

export interface AuthModelsResult {
	success: boolean;
	models: AuthModelInfo[];
	error?: string;
}

export interface AuthModelInfo {
	id: string;
	name: string;
}

export interface AuthAccount {
	id: string;
	name: string;
	provider: string;
	email?: string;
	status: "ready" | "cooling" | "error";
	disabled: boolean;
}

export interface UniversalProviderInfo {
	id: string;
	name: string;
	baseURL: string;
	modelId: string;
	isBuiltIn: boolean;
	iconAssetName: string | null;
	color: string;
	supportedAgents: string[];
	isEnabled: boolean;
	createdAt: string;
	updatedAt: string;
}

export interface UniversalProviderListResult {
	providers: UniversalProviderInfo[];
}

export interface UniversalProviderAddParams {
	name: string;
	baseURL: string;
	modelId?: string;
	color?: string;
	supportedAgents?: string[];
	isEnabled?: boolean;
}

export interface UniversalProviderUpdateParams {
	id: string;
	name?: string;
	baseURL?: string;
	modelId?: string;
	color?: string;
	supportedAgents?: string[];
	isEnabled?: boolean;
}

export interface OAuthStartResult {
	success: boolean;
	url?: string;
	state?: string;
	error?: string;
}

export interface OAuthPollResult {
	status: "pending" | "success" | "error";
	error?: string;
}

export interface StatsRequestLogInfo {
	id: string;
	timestamp: string;
	method: string;
	endpoint: string;
	provider: string | null;
	model: string | null;
	inputTokens: number | null;
	outputTokens: number | null;
	durationMs: number;
	statusCode: number | null;
	requestSize: number;
	responseSize: number;
	errorMessage: string | null;
}

export interface StatsProviderInfo {
	provider: string;
	requestCount: number;
	inputTokens: number;
	outputTokens: number;
	averageDurationMs: number;
}

export interface StatsModelInfo {
	model: string;
	provider: string | null;
	requestCount: number;
	inputTokens: number;
	outputTokens: number;
	averageDurationMs: number;
}

export interface StatsAggregateInfo {
	totalRequests: number;
	successfulRequests: number;
	failedRequests: number;
	totalInputTokens: number;
	totalOutputTokens: number;
	averageDurationMs: number;
	byProvider: Record<string, StatsProviderInfo>;
	byModel: Record<string, StatsModelInfo>;
}

export interface StatsListResult {
	entries: StatsRequestLogInfo[];
}

export interface StatsGetResult {
	stats: StatsAggregateInfo;
}

export interface StatsAddParams {
	method: string;
	endpoint: string;
	provider?: string;
	model?: string;
	inputTokens?: number;
	outputTokens?: number;
	durationMs: number;
	statusCode?: number;
	requestSize?: number;
	responseSize?: number;
	errorMessage?: string;
}

export type TunnelStatus =
	| "idle"
	| "starting"
	| "active"
	| "stopping"
	| "error";

export interface TunnelStartResult {
	success: boolean;
	error?: string;
}

export interface TunnelStatusResult {
	status: TunnelStatus;
	publicURL: string | null;
	errorMessage: string | null;
	startTime: string | null;
}

export interface TunnelInstallationResult {
	isInstalled: boolean;
	path: string | null;
	version: string | null;
}

export interface FallbackEntryInfo {
	id: string;
	provider: string;
	modelId: string;
	priority: number;
}

export interface VirtualModelInfo {
	id: string;
	name: string;
	fallbackEntries: FallbackEntryInfo[];
	isEnabled: boolean;
}

export interface FallbackConfigResult {
	isEnabled: boolean;
	virtualModels: VirtualModelInfo[];
}

export interface FallbackListModelsResult {
	models: VirtualModelInfo[];
}

export interface VirtualModelUpdateParams {
	id: string;
	name?: string;
	isEnabled?: boolean;
}

export interface FallbackRouteStateInfo {
	virtualModelName: string;
	currentEntryIndex: number;
	currentEntry: FallbackEntryInfo;
	lastUpdated: string;
	totalEntries: number;
}

export interface FallbackRouteStatesResult {
	states: FallbackRouteStateInfo[];
}

export interface ProxyConfigGetAllResult {
	success: boolean;
	config?: {
		debug: boolean;
		routingStrategy: string;
		requestRetry: number;
		maxRetryInterval: number;
		proxyURL: string;
		loggingToFile: boolean;
	};
	error?: string;
}

export interface ProxyConfigGetResult {
	success: boolean;
	key?: string;
	value?: unknown;
	error?: string;
}

export interface APIKeysListResult {
	success: boolean;
	keys: string[];
	error?: string;
}

export interface LogEntryInfo {
	id: number;
	timestamp: string;
	method: string;
	path: string;
	statusCode: number;
	duration: number;
	provider?: string;
	model?: string;
	inputTokens?: number;
	outputTokens?: number;
	error?: string;
}

export interface LogsFetchResult {
	success: boolean;
	logs: LogEntryInfo[];
	total: number;
	lastId: number;
	error?: string;
}

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Create a JSON-RPC 2.0 request object
 */
export function createRequest<M extends MethodName>(
	id: RequestId,
	method: M,
	params?: MethodParams<M>,
): JsonRpcRequest<MethodParams<M>> {
	return {
		jsonrpc: JSONRPC_VERSION,
		id,
		method,
		...(params !== undefined && { params }),
	};
}

/**
 * Create a JSON-RPC 2.0 success response
 */
export function createSuccessResponse<R>(
	id: RequestId,
	result: R,
): JsonRpcSuccessResponse<R> {
	return {
		jsonrpc: JSONRPC_VERSION,
		id,
		result,
	};
}

/**
 * Create a JSON-RPC 2.0 error response
 */
export function createErrorResponse(
	id: RequestId | null,
	code: number,
	message: string,
	data?: unknown,
): JsonRpcErrorResponse {
	return {
		jsonrpc: JSONRPC_VERSION,
		id,
		error: {
			code,
			message,
			...(data !== undefined && { data }),
		},
	};
}

/**
 * Check if a response is an error response
 */
export function isErrorResponse(
	response: JsonRpcResponse,
): response is JsonRpcErrorResponse {
	return "error" in response;
}

/**
 * Check if a response is a success response
 */
export function isSuccessResponse<R>(
	response: JsonRpcResponse<R>,
): response is JsonRpcSuccessResponse<R> {
	return "result" in response;
}

/**
 * Parse a JSON string into a JsonRpcRequest, with validation
 */
export function parseRequest(
	data: string,
): JsonRpcRequest | JsonRpcErrorResponse {
	let parsed: unknown;
	try {
		parsed = JSON.parse(data);
	} catch {
		return createErrorResponse(null, ErrorCodes.PARSE_ERROR, "Parse error");
	}

	if (typeof parsed !== "object" || parsed === null) {
		return createErrorResponse(
			null,
			ErrorCodes.INVALID_REQUEST,
			"Invalid Request",
		);
	}

	const obj = parsed as Record<string, unknown>;

	if (obj.jsonrpc !== JSONRPC_VERSION) {
		return createErrorResponse(
			null,
			ErrorCodes.INVALID_REQUEST,
			"Invalid Request: missing or invalid jsonrpc version",
		);
	}

	if (typeof obj.method !== "string") {
		return createErrorResponse(
			null,
			ErrorCodes.INVALID_REQUEST,
			"Invalid Request: method must be a string",
		);
	}

	if (
		obj.id === undefined ||
		(typeof obj.id !== "string" && typeof obj.id !== "number")
	) {
		return createErrorResponse(
			null,
			ErrorCodes.INVALID_REQUEST,
			"Invalid Request: id must be a string or number",
		);
	}

	return {
		jsonrpc: JSONRPC_VERSION,
		id: obj.id as RequestId,
		method: obj.method,
		params: obj.params as Record<string, unknown> | undefined,
	};
}

/**
 * Message delimiter for socket communication (newline-delimited JSON)
 */
export const MESSAGE_DELIMITER = "\n";

/**
 * Encode a message for socket transmission
 */
export function encodeMessage(
	message: JsonRpcRequest | JsonRpcResponse,
): string {
	return JSON.stringify(message) + MESSAGE_DELIMITER;
}

/**
 * Create message buffer parser for streaming socket data
 */
export function createMessageParser(
	onMessage: (message: string) => void,
): (chunk: Buffer | string) => void {
	let buffer = "";

	return (chunk: Buffer | string) => {
		buffer += typeof chunk === "string" ? chunk : chunk.toString("utf-8");

		let delimiterIndex = buffer.indexOf(MESSAGE_DELIMITER);
		while (delimiterIndex !== -1) {
			const message = buffer.slice(0, delimiterIndex);
			buffer = buffer.slice(delimiterIndex + MESSAGE_DELIMITER.length);

			if (message.trim()) {
				onMessage(message);
			}
			delimiterIndex = buffer.indexOf(MESSAGE_DELIMITER);
		}
	};
}
