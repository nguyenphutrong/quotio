import { AIProvider } from "../../models/provider.ts";
import type {
	ModelQuota,
	ProviderQuotaData,
	QuotaFetchResult,
	QuotaFetcher,
} from "./types.ts";
import { fetchWithTimeout, getAuthDir, readAuthFiles } from "./types.ts";

const QUOTA_API_URL =
	"https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels";
const SUBSCRIPTION_API_URL =
	"https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist";
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const CLIENT_ID =
	"1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com";
const CLIENT_SECRET = "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";
const USER_AGENT = "antigravity/1.11.3 Darwin/arm64";

interface AntigravityAuthFile {
	access_token: string;
	email: string;
	expired?: string;
	expires_in?: number;
	refresh_token?: string;
	timestamp?: number;
	type?: string;
}

interface TokenRefreshResponse {
	access_token: string;
	expires_in: number;
	token_type?: string;
}

interface QuotaInfo {
	remainingFraction?: number;
	resetTime?: string;
}

interface ModelInfo {
	quotaInfo?: QuotaInfo;
}

interface QuotaAPIResponse {
	models: Record<string, ModelInfo>;
}

interface SubscriptionTier {
	id: string;
	name: string;
	description: string;
}

interface SubscriptionInfo {
	currentTier?: SubscriptionTier;
	paidTier?: SubscriptionTier;
	cloudaicompanionProject?: string;
}

function isTokenExpired(expiredStr?: string): boolean {
	if (!expiredStr) return true;

	let expiryDate = new Date(expiredStr);
	if (Number.isNaN(expiryDate.getTime())) {
		expiryDate = new Date(expiredStr.replace(/\.\d+/, ""));
	}

	if (Number.isNaN(expiryDate.getTime())) return true;
	return new Date() > expiryDate;
}

async function refreshAccessToken(
	refreshToken: string,
): Promise<TokenRefreshResponse | null> {
	try {
		const params = new URLSearchParams({
			client_id: CLIENT_ID,
			client_secret: CLIENT_SECRET,
			refresh_token: refreshToken,
			grant_type: "refresh_token",
		});

		const response = await fetchWithTimeout({
			url: TOKEN_URL,
			method: "POST",
			headers: {
				"Content-Type": "application/x-www-form-urlencoded",
			},
			body: params.toString(),
		});

		if (!response.ok) {
			return null;
		}

		return (await response.json()) as TokenRefreshResponse;
	} catch {
		return null;
	}
}

async function persistRefreshedToken(
	filePath: string,
	newAccessToken: string,
	expiresIn: number,
): Promise<void> {
	try {
		const file = Bun.file(filePath);
		const json = (await file.json()) as AntigravityAuthFile;

		json.access_token = newAccessToken;
		json.expired = new Date(Date.now() + expiresIn * 1000).toISOString();
		await Bun.write(filePath, JSON.stringify(json, null, 2));
	} catch {
		// Token refresh succeeded in memory; file update is non-critical
	}
}

async function fetchSubscriptionInfo(
	accessToken: string,
): Promise<SubscriptionInfo | null> {
	try {
		const payload = { metadata: { ideType: "ANTIGRAVITY" } };

		const response = await fetchWithTimeout({
			url: SUBSCRIPTION_API_URL,
			method: "POST",
			headers: {
				Authorization: `Bearer ${accessToken}`,
				"User-Agent": USER_AGENT,
				"Content-Type": "application/json",
			},
			body: JSON.stringify(payload),
		});

		if (!response.ok) {
			return null;
		}

		return (await response.json()) as SubscriptionInfo;
	} catch {
		return null;
	}
}

async function fetchQuota(
	accessToken: string,
	projectId?: string,
): Promise<ProviderQuotaData | null> {
	const payload: Record<string, string> = {};
	if (projectId) {
		payload.project = projectId;
	}

	let lastError: Error | null = null;

	for (let attempt = 1; attempt <= 3; attempt++) {
		try {
			const response = await fetchWithTimeout({
				url: QUOTA_API_URL,
				method: "POST",
				headers: {
					Authorization: `Bearer ${accessToken}`,
					"User-Agent": USER_AGENT,
					"Content-Type": "application/json",
				},
				body: JSON.stringify(payload),
			});

			if (response.status === 403) {
				return {
					models: [],
					lastUpdated: new Date(),
					isForbidden: true,
				};
			}

			if (!response.ok) {
				throw new Error(`HTTP ${response.status}`);
			}

			const data = (await response.json()) as QuotaAPIResponse;
			const models: ModelQuota[] = [];

			for (const [name, info] of Object.entries(data.models ?? {})) {
				const isGeminiOrClaude =
					name.includes("gemini") || name.includes("claude");
				if (!isGeminiOrClaude) continue;

				if (info.quotaInfo) {
					const percentage = (info.quotaInfo.remainingFraction ?? 0) * 100;
					const resetTime = info.quotaInfo.resetTime ?? "";
					models.push({
						name,
						percentage,
						resetTime,
					});
				}
			}

			return {
				models,
				lastUpdated: new Date(),
				isForbidden: false,
			};
		} catch (error) {
			lastError = error instanceof Error ? error : new Error(String(error));
			if (attempt < 3) {
				await new Promise((resolve) => setTimeout(resolve, 1000));
			}
		}
	}

	throw lastError ?? new Error("Unknown error");
}

function extractEmailFromFilename(filename: string): string {
	return filename
		.replace(/^antigravity-/, "")
		.replace(/\.json$/, "")
		.replace(/_/g, ".")
		.replace(/\.gmail\.com$/, "@gmail.com");
}

export class AntigravityQuotaFetcher implements QuotaFetcher {
	readonly provider = AIProvider.ANTIGRAVITY;

	async fetchAll(): Promise<QuotaFetchResult[]> {
		const authFiles = await readAuthFiles("antigravity-");
		if (authFiles.length === 0) return [];

		const results: QuotaFetchResult[] = [];

		for (const authFile of authFiles) {
			const email = extractEmailFromFilename(authFile.name);

			try {
				const filePath = authFile.path;
				const file = Bun.file(filePath);
				const content = (await file.json()) as AntigravityAuthFile;

				let accessToken = content.access_token;

				if (isTokenExpired(content.expired) && content.refresh_token) {
					const refreshed = await refreshAccessToken(content.refresh_token);
					if (refreshed) {
						accessToken = refreshed.access_token;
						await persistRefreshedToken(
							filePath,
							refreshed.access_token,
							refreshed.expires_in,
						);
					}
				}

				if (!accessToken) {
					results.push({
						account: email,
						provider: this.provider,
						error: "No access token available",
					});
					continue;
				}

				const subscriptionInfo = await fetchSubscriptionInfo(accessToken);
				const projectId = subscriptionInfo?.cloudaicompanionProject;
				const quotaData = await fetchQuota(accessToken, projectId ?? undefined);

				if (!quotaData) {
					results.push({
						account: email,
						provider: this.provider,
						error: "Failed to fetch quota",
					});
					continue;
				}

				const effectiveTier =
					subscriptionInfo?.paidTier ?? subscriptionInfo?.currentTier;
				if (effectiveTier) {
					quotaData.planType = effectiveTier.name;
				}

				results.push({
					account: email,
					provider: this.provider,
					data: quotaData,
				});
			} catch (error) {
				results.push({
					account: email,
					provider: this.provider,
					error: error instanceof Error ? error.message : "Unknown error",
				});
			}
		}

		return results;
	}

	async fetchForAccount(
		account: string,
		accessToken: string,
	): Promise<QuotaFetchResult> {
		try {
			const subscriptionInfo = await fetchSubscriptionInfo(accessToken);
			const projectId = subscriptionInfo?.cloudaicompanionProject;
			const quotaData = await fetchQuota(accessToken, projectId ?? undefined);

			if (!quotaData) {
				return {
					account,
					provider: this.provider,
					error: "Failed to fetch quota",
				};
			}

			const effectiveTier =
				subscriptionInfo?.paidTier ?? subscriptionInfo?.currentTier;
			if (effectiveTier) {
				quotaData.planType = effectiveTier.name;
			}

			return {
				account,
				provider: this.provider,
				data: quotaData,
			};
		} catch (error) {
			return {
				account,
				provider: this.provider,
				error: error instanceof Error ? error.message : "Unknown error",
			};
		}
	}
}
