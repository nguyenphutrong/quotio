import type { AIProvider } from "../../models/provider.ts";
import type { ModelQuota, ProviderQuotaData } from "../../models/quota.ts";
import { createEmptyQuotaData } from "../../models/quota.ts";

export type { ModelQuota, ProviderQuotaData };
export { createEmptyQuotaData };

export interface QuotaFetchResult {
	account: string;
	provider: AIProvider;
	data?: ProviderQuotaData;
	error?: string;
}

export interface QuotaFetcher {
	readonly provider: AIProvider;
	fetchAll(): Promise<QuotaFetchResult[]>;
	fetchForAccount(
		account: string,
		accessToken: string,
	): Promise<QuotaFetchResult>;
}

export interface FetchConfig {
	url: string;
	method?: "GET" | "POST";
	headers?: Record<string, string>;
	body?: string;
	timeoutMs?: number;
}

export const DEFAULT_QUOTA_TIMEOUT_MS = 30_000;

export async function fetchWithTimeout(config: FetchConfig): Promise<Response> {
	const controller = new AbortController();
	const timeoutId = setTimeout(
		() => controller.abort(),
		config.timeoutMs ?? DEFAULT_QUOTA_TIMEOUT_MS,
	);

	try {
		const response = await fetch(config.url, {
			method: config.method ?? "GET",
			headers: config.headers,
			body: config.body,
			signal: controller.signal,
		});
		return response;
	} finally {
		clearTimeout(timeoutId);
	}
}

export interface LocalAuthFile {
	name: string;
	path: string;
	provider: string;
	accessToken?: string;
	refreshToken?: string;
	idToken?: string;
	email?: string;
	account?: string;
	expiresAt?: number | string;
	/** Auth method for Kiro: "Social" (Google OAuth) or "IdC" (AWS Builder ID) */
	authMethod?: "Social" | "IdC";
	/** Client ID for AWS OIDC token refresh */
	clientId?: string;
	/** Client secret for AWS OIDC token refresh */
	clientSecret?: string;
}

export function getAuthDir(): string {
	const home = process.env.HOME ?? Bun.env.HOME ?? "";
	return `${home}/.cli-proxy-api`;
}

export async function readAuthFiles(
	providerPrefix: string,
): Promise<LocalAuthFile[]> {
	const authDir = getAuthDir();
	const results: LocalAuthFile[] = [];

	try {
		const { readdir } = await import("node:fs/promises");
		const files = await readdir(authDir);

		for (const fileName of files) {
			if (!fileName.startsWith(providerPrefix) || !fileName.endsWith(".json")) {
				continue;
			}

			const filePath = `${authDir}/${fileName}`;
			try {
				const file = Bun.file(filePath);
				const content = await file.json();

				results.push({
					name: fileName,
					path: filePath,
					provider: providerPrefix.replace(/-$/, ""),
					accessToken: content.access_token ?? content.accessToken,
					refreshToken: content.refresh_token ?? content.refreshToken,
					idToken: content.id_token ?? content.idToken,
					email: content.email,
					account: content.account,
					expiresAt: content.expires_at ?? content.expiresAt,
					authMethod: content.auth_method ?? content.authMethod,
					clientId: content.client_id ?? content.clientId,
					clientSecret: content.client_secret ?? content.clientSecret,
				});
			} catch {
				// Skip invalid JSON files
			}
		}
	} catch {
		// Auth directory doesn't exist
	}

	return results;
}

export function calculatePercentage(
	used: number | undefined,
	limit: number | undefined,
): number {
	if (limit === undefined || limit <= 0) return -1;
	if (used === undefined) return -1;
	return Math.min(100, Math.round((used / limit) * 100));
}

export function formatResetTime(
	resetAt: string | number | Date | undefined,
): string {
	if (!resetAt) return "";
	if (typeof resetAt === "number") {
		return new Date(resetAt * 1000).toISOString();
	}
	if (resetAt instanceof Date) {
		return resetAt.toISOString();
	}
	return resetAt;
}

export function decodeJWTPayload<T = Record<string, unknown>>(
	token: string,
): T | null {
	try {
		const parts = token.split(".");
		if (parts.length !== 3) return null;

		const payload = parts[1];
		if (!payload) return null;

		const base64 = payload.replace(/-/g, "+").replace(/_/g, "/");
		const decoded = atob(base64);
		return JSON.parse(decoded) as T;
	} catch {
		return null;
	}
}
