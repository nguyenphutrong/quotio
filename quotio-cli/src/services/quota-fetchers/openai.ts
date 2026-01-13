import { AIProvider } from "../../models/provider.ts";
import type {
	LocalAuthFile,
	ModelQuota,
	ProviderQuotaData,
	QuotaFetchResult,
	QuotaFetcher,
} from "./types.ts";
import {
	createEmptyQuotaData,
	fetchWithTimeout,
	getAuthDir,
	readAuthFiles,
} from "./types.ts";

const CHATGPT_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";
const TOKEN_REFRESH_URL = "https://token.oaifree.com/api/auth/refresh";

interface WindowInfo {
	used_percent?: number;
	limit_window_seconds?: number;
	reset_after_seconds?: number;
	reset_at?: number;
}

interface RateLimitInfo {
	allowed?: boolean;
	limit_reached?: boolean;
	primary_window?: WindowInfo;
	secondary_window?: WindowInfo;
}

interface CodexUsageResponse {
	plan_type?: string;
	rate_limit?: RateLimitInfo;
	code_review_rate_limit?: RateLimitInfo;
	credits?: {
		has_credits?: boolean;
		unlimited?: boolean;
		balance?: string;
	};
}

interface TokenRefreshResponse {
	access_token: string;
}

type FetchResult =
	| { status: "success"; data: CodexUsageResponse }
	| { status: "auth_error" }
	| { status: "error"; message: string };

async function refreshAccessToken(
	refreshToken: string,
): Promise<string | null> {
	try {
		const response = await fetchWithTimeout({
			url: TOKEN_REFRESH_URL,
			method: "POST",
			headers: {
				"Content-Type": "application/x-www-form-urlencoded",
			},
			body: `refresh_token=${encodeURIComponent(refreshToken)}`,
		});

		if (!response.ok) return null;

		const data = (await response.json()) as TokenRefreshResponse;
		return data.access_token ?? null;
	} catch {
		return null;
	}
}

async function fetchUsageFromAPI(accessToken: string): Promise<FetchResult> {
	try {
		const response = await fetchWithTimeout({
			url: CHATGPT_USAGE_URL,
			headers: {
				Accept: "application/json",
				Authorization: `Bearer ${accessToken}`,
			},
		});

		if (response.status === 401) {
			return { status: "auth_error" };
		}

		if (!response.ok) {
			return { status: "error", message: `HTTP ${response.status}` };
		}

		const json = (await response.json()) as CodexUsageResponse;
		return { status: "success", data: json };
	} catch (err) {
		return {
			status: "error",
			message: err instanceof Error ? err.message : String(err),
		};
	}
}

function formatResetTime(resetAt: number | undefined): string {
	if (!resetAt) return "";
	return new Date(resetAt * 1000).toISOString();
}

function convertToProviderQuota(data: CodexUsageResponse): ProviderQuotaData {
	const models: ModelQuota[] = [];
	const rateLimit = data.rate_limit;

	const primaryUsed = rateLimit?.primary_window?.used_percent ?? 0;
	models.push({
		name: "codex-session",
		percentage: Math.max(0, 100 - primaryUsed),
		resetTime: formatResetTime(rateLimit?.primary_window?.reset_at),
	});

	const secondaryUsed = rateLimit?.secondary_window?.used_percent ?? 0;
	models.push({
		name: "codex-weekly",
		percentage: Math.max(0, 100 - secondaryUsed),
		resetTime: formatResetTime(rateLimit?.secondary_window?.reset_at),
	});

	return {
		models,
		lastUpdated: new Date(),
		isForbidden: rateLimit?.limit_reached ?? false,
		planType: data.plan_type,
	};
}

function isTokenExpired(expiredStr: string | undefined): boolean {
	if (!expiredStr) return true;
	try {
		const expiryDate = new Date(expiredStr);
		return Date.now() > expiryDate.getTime();
	} catch {
		return true;
	}
}

async function updateAuthFile(
	filePath: string,
	accessToken: string,
): Promise<void> {
	try {
		const file = Bun.file(filePath);
		const content = await file.json();
		content.access_token = accessToken;
		await Bun.write(filePath, JSON.stringify(content, null, 2));
	} catch {
		// Ignore update failures
	}
}

export class OpenAIQuotaFetcher implements QuotaFetcher {
	readonly provider = AIProvider.CODEX;

	async fetchAll(): Promise<QuotaFetchResult[]> {
		const authFiles = await readAuthFiles("codex-");
		if (authFiles.length === 0) return [];

		const results = await Promise.all(
			authFiles.map((file) => this.fetchFromAuthFile(file)),
		);

		return results.filter((r): r is QuotaFetchResult => r !== null);
	}

	async fetchForAccount(
		account: string,
		accessToken: string,
	): Promise<QuotaFetchResult> {
		const result = await fetchUsageFromAPI(accessToken);

		if (result.status === "auth_error") {
			return {
				account,
				provider: this.provider,
				data: { ...createEmptyQuotaData(), isForbidden: true },
			};
		}

		if (result.status === "error") {
			return {
				account,
				provider: this.provider,
				error: result.message,
			};
		}

		return {
			account,
			provider: this.provider,
			data: convertToProviderQuota(result.data),
		};
	}

	private async fetchFromAuthFile(
		file: LocalAuthFile,
	): Promise<QuotaFetchResult | null> {
		let { accessToken, refreshToken, email } = file;
		if (!accessToken) return null;

		const account =
			email ?? file.name.replace("codex-", "").replace(".json", "");

		const authFileContent = await this.readAuthFileContent(file.path);
		const isExpired = isTokenExpired(authFileContent?.expired);

		if (isExpired && refreshToken) {
			const newToken = await refreshAccessToken(refreshToken);
			if (newToken) {
				accessToken = newToken;
				await updateAuthFile(file.path, newToken);
			}
		}

		return this.fetchForAccount(account, accessToken);
	}

	private async readAuthFileContent(
		filePath: string,
	): Promise<{ expired?: string } | null> {
		try {
			const file = Bun.file(filePath);
			return (await file.json()) as { expired?: string };
		} catch {
			return null;
		}
	}
}
