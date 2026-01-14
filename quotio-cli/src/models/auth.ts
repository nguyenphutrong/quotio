import type { AIProvider } from "./provider.ts";

export type AuthStatus = "ready" | "cooling" | "error";

export interface AuthFile {
	id: string;
	name: string;
	provider: string;
	label?: string;
	status: AuthStatus;
	statusMessage?: string;
	disabled: boolean;
	unavailable: boolean;
	runtimeOnly?: boolean;
	source?: string;
	path?: string;
	email?: string;
	accountType?: string;
	account?: string;
	authIndex?: string;
	createdAt?: string;
	updatedAt?: string;
	lastRefresh?: string;
}

export interface AuthFilesResponse {
	files: AuthFile[];
}

export interface OAuthURLResponse {
	status: string;
	url?: string;
	state?: string;
	error?: string;
}

export interface OAuthStatusResponse {
	status: string;
	error?: string;
}

export interface APIKeysResponse {
	"api-keys": string[];
}

export interface LogEntry {
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

export interface LogsResponse {
	logs: LogEntry[];
	total: number;
	lastId: number;
}

export function parseAuthFile(json: Record<string, unknown>): AuthFile {
	return {
		id: String(json.id ?? ""),
		name: String(json.name ?? ""),
		provider: String(json.provider ?? ""),
		label: json.label as string | undefined,
		status: (json.status as AuthStatus) ?? "error",
		statusMessage: json.status_message as string | undefined,
		disabled: Boolean(json.disabled),
		unavailable: Boolean(json.unavailable),
		runtimeOnly: json.runtime_only as boolean | undefined,
		source: json.source as string | undefined,
		path: json.path as string | undefined,
		email: json.email as string | undefined,
		accountType: json.account_type as string | undefined,
		account: json.account as string | undefined,
		authIndex: json.auth_index as string | undefined,
		createdAt: json.created_at as string | undefined,
		updatedAt: json.updated_at as string | undefined,
		lastRefresh: json.last_refresh as string | undefined,
	};
}

export function getQuotaLookupKey(auth: AuthFile): string {
	if (auth.email && auth.email.length > 0) {
		return auth.email;
	}
	if (auth.account && auth.account.length > 0) {
		return auth.account;
	}
	let key = auth.name;
	if (key.startsWith("github-copilot-")) {
		key = key.slice("github-copilot-".length);
	}
	if (key.endsWith(".json")) {
		key = key.slice(0, -".json".length);
	}
	return key;
}

export function isAuthReady(auth: AuthFile): boolean {
	return auth.status === "ready" && !auth.disabled && !auth.unavailable;
}

export function parseProviderFromAuth(auth: AuthFile): AIProvider | null {
	const { parseProvider } = require("./provider.ts");
	if (auth.provider === "copilot") {
		return parseProvider("github-copilot");
	}
	return parseProvider(auth.provider);
}
