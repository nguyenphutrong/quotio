import { AIProvider } from "../../models/provider.ts";
import type {
	ModelQuota,
	ProviderQuotaData,
	QuotaFetchResult,
	QuotaFetcher,
} from "./types.ts";
import { decodeJWTPayload, fetchWithTimeout } from "./types.ts";

const AUTH_FILE_PATH = "~/.codex/auth.json";
const USAGE_API_URL = "https://chatgpt.com/backend-api/wham/usage";
const TOKEN_REFRESH_URL = "https://auth.openai.com/oauth/token";
const CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";

interface CodexAuthFile {
	OPENAI_API_KEY?: string;
	tokens?: {
		id_token?: string;
		access_token?: string;
		refresh_token?: string;
		account_id?: string;
	};
	last_refresh?: string;
}

interface CodexJWTPayload {
	email?: string;
	email_verified?: boolean;
	exp?: number;
	"https://api.openai.com/auth"?: {
		chatgpt_plan_type?: string;
		chatgpt_account_id?: string;
		chatgpt_user_id?: string;
		organizations?: Array<{ title?: string }>;
		chatgpt_subscription_active_until?: string;
	};
}

interface UsageRateLimit {
	limit_reached?: boolean;
	primary_window?: {
		used_percent?: number;
		reset_at?: number;
	};
	secondary_window?: {
		used_percent?: number;
		reset_at?: number;
	};
}

interface UsageResponse {
	plan_type?: string;
	rate_limit?: UsageRateLimit;
}

interface TokenRefreshResponse {
	access_token: string;
	expires_in?: number;
}

function getExpandedPath(path: string): string {
	const home = process.env.HOME ?? Bun.env.HOME ?? "";
	return path.replace(/^~/, home);
}

function isJWTExpired(token: string): boolean {
	const payload = decodeJWTPayload<{ exp?: number }>(token);
	if (!payload?.exp) return true;

	const expiryDate = new Date(payload.exp * 1000);
	const bufferTime = 60 * 1000;
	return expiryDate.getTime() - bufferTime < Date.now();
}

async function readAuthFile(): Promise<CodexAuthFile | null> {
	try {
		const file = Bun.file(getExpandedPath(AUTH_FILE_PATH));
		const exists = await file.exists();
		if (!exists) return null;
		return (await file.json()) as CodexAuthFile;
	} catch {
		return null;
	}
}

async function refreshAccessToken(
	refreshToken: string,
): Promise<string | null> {
	try {
		const response = await fetchWithTimeout({
			url: TOKEN_REFRESH_URL,
			method: "POST",
			headers: {
				"Content-Type": "application/json",
			},
			body: JSON.stringify({
				grant_type: "refresh_token",
				refresh_token: refreshToken,
				client_id: CODEX_CLIENT_ID,
			}),
		});

		if (!response.ok) return null;

		const data = (await response.json()) as TokenRefreshResponse;
		return data.access_token;
	} catch {
		return null;
	}
}

async function fetchUsage(accessToken: string): Promise<UsageResponse | null> {
	try {
		const response = await fetchWithTimeout({
			url: USAGE_API_URL,
			headers: {
				Authorization: `Bearer ${accessToken}`,
				Accept: "application/json",
			},
		});

		if (!response.ok) return null;
		return (await response.json()) as UsageResponse;
	} catch {
		return null;
	}
}

function buildQuotaFromUsage(
	usageData: UsageResponse,
	planType?: string,
): ProviderQuotaData {
	const models: ModelQuota[] = [];
	const rateLimit = usageData.rate_limit;

	const primaryWindow = rateLimit?.primary_window;
	if (primaryWindow) {
		const sessionUsedPercent = primaryWindow.used_percent ?? 0;
		const sessionResetTime = primaryWindow.reset_at
			? new Date(primaryWindow.reset_at * 1000).toISOString()
			: "";

		models.push({
			name: "codex-session",
			percentage: 100 - sessionUsedPercent,
			resetTime: sessionResetTime,
		});
	}

	const secondaryWindow = rateLimit?.secondary_window;
	if (secondaryWindow) {
		const weeklyUsedPercent = secondaryWindow.used_percent ?? 0;
		const weeklyResetTime = secondaryWindow.reset_at
			? new Date(secondaryWindow.reset_at * 1000).toISOString()
			: "";

		models.push({
			name: "codex-weekly",
			percentage: 100 - weeklyUsedPercent,
			resetTime: weeklyResetTime,
		});
	}

	if (models.length === 0) {
		models.push({
			name: "codex-usage",
			percentage: 100,
			resetTime: "",
		});
	}

	return {
		models,
		lastUpdated: new Date(),
		isForbidden: rateLimit?.limit_reached ?? false,
		planType: planType ?? usageData.plan_type,
	};
}

export class CodexQuotaFetcher implements QuotaFetcher {
	readonly provider = AIProvider.CODEX;

	async fetchAll(): Promise<QuotaFetchResult[]> {
		const authFile = await readAuthFile();
		const tokens = authFile?.tokens;
		const initialToken = tokens?.access_token;
		if (!tokens || !initialToken) return [];

		let email = "Codex User";
		let planType: string | undefined;

		if (tokens.id_token) {
			const payload = decodeJWTPayload<CodexJWTPayload>(tokens.id_token);
			if (payload) {
				email = payload.email ?? email;
				planType = payload["https://api.openai.com/auth"]?.chatgpt_plan_type;
			}
		}

		let accessToken = initialToken;

		if (isJWTExpired(accessToken) && tokens.refresh_token) {
			const newToken = await refreshAccessToken(tokens.refresh_token);
			if (newToken) {
				accessToken = newToken;
			}
		}

		const usageData = await fetchUsage(accessToken);

		if (!usageData) {
			return [
				{
					account: email,
					provider: this.provider,
					error: "Failed to fetch usage data",
				},
			];
		}

		const quotaData = buildQuotaFromUsage(usageData, planType);

		return [
			{
				account: email,
				provider: this.provider,
				data: quotaData,
			},
		];
	}

	async fetchForAccount(
		account: string,
		accessToken: string,
	): Promise<QuotaFetchResult> {
		const usageData = await fetchUsage(accessToken);

		if (!usageData) {
			return {
				account,
				provider: this.provider,
				error: "Failed to fetch usage data",
			};
		}

		const quotaData = buildQuotaFromUsage(usageData);

		return {
			account,
			provider: this.provider,
			data: quotaData,
		};
	}
}
