import { AIProvider } from "../../models/provider.ts";
import type {
	LocalAuthFile,
	ModelQuota,
	ProviderQuotaData,
	QuotaFetchResult,
	QuotaFetcher,
} from "./types.ts";
import { fetchWithTimeout, getAuthDir, readAuthFiles } from "./types.ts";

const USAGE_ENDPOINT =
	"https://codewhisperer.us-east-1.amazonaws.com/getUsageLimits";
const SOCIAL_TOKEN_ENDPOINT =
	"https://prod.us-east-1.auth.desktop.kiro.dev/refreshToken";
const IDC_TOKEN_ENDPOINT = "https://oidc.us-east-1.amazonaws.com/token";

const REFRESH_BUFFER_SECONDS = 5 * 60;

interface KiroUsageBreakdown {
	displayName?: string;
	resourceType?: string;
	currentUsage?: number;
	currentUsageWithPrecision?: number;
	usageLimit?: number;
	usageLimitWithPrecision?: number;
	nextDateReset?: number;
	freeTrialInfo?: {
		currentUsage?: number;
		currentUsageWithPrecision?: number;
		usageLimit?: number;
		usageLimitWithPrecision?: number;
		freeTrialStatus?: string;
		freeTrialExpiry?: number;
	};
}

interface KiroUsageResponse {
	usageBreakdownList?: KiroUsageBreakdown[];
	subscriptionInfo?: {
		subscriptionTitle?: string;
		type?: string;
	};
	userInfo?: {
		email?: string;
		userId?: string;
	};
	nextDateReset?: number;
}

interface KiroTokenResponse {
	accessToken: string;
	expiresIn: number;
	tokenType?: string;
	refreshToken?: string;
}

interface UsageAPIResult {
	statusCode: number;
	quotaData: ProviderQuotaData | null;
}

function parseExpiryDate(expiresAt: string | number | undefined): Date | null {
	if (!expiresAt) return null;

	if (typeof expiresAt === "number") {
		return new Date(expiresAt * 1000);
	}

	const date = new Date(expiresAt);
	return Number.isNaN(date.getTime()) ? null : date;
}

function shouldRefreshToken(authFile: LocalAuthFile): {
	shouldRefresh: boolean;
	reason: string;
} {
	const expiresAt = authFile.expiresAt;
	if (!expiresAt) {
		return { shouldRefresh: false, reason: "no expiry info" };
	}

	const expiryDate = parseExpiryDate(expiresAt);
	if (!expiryDate) {
		return { shouldRefresh: false, reason: "unparseable expiry" };
	}

	const timeRemainingMs = expiryDate.getTime() - Date.now();
	const timeRemainingSec = timeRemainingMs / 1000;

	if (timeRemainingSec <= 0) {
		return {
			shouldRefresh: true,
			reason: `expired ${Math.abs(Math.floor(timeRemainingSec))}s ago`,
		};
	}

	if (timeRemainingSec < REFRESH_BUFFER_SECONDS) {
		return {
			shouldRefresh: true,
			reason: `expiring in ${Math.floor(timeRemainingSec)}s (< 5min buffer)`,
		};
	}

	return {
		shouldRefresh: false,
		reason: `${Math.floor(timeRemainingSec)}s remaining`,
	};
}

async function refreshSocialToken(
	refreshToken: string,
	filePath: string,
): Promise<{ accessToken: string; expiresAt: Date } | null> {
	try {
		const response = await fetchWithTimeout({
			url: SOCIAL_TOKEN_ENDPOINT,
			method: "POST",
			headers: {
				"Content-Type": "application/json",
			},
			body: JSON.stringify({ refreshToken }),
		});

		if (!response.ok) {
			return null;
		}

		const tokenResponse = (await response.json()) as KiroTokenResponse;
		const newExpiry = new Date(Date.now() + tokenResponse.expiresIn * 1000);

		await persistRefreshedToken(
			filePath,
			tokenResponse.accessToken,
			tokenResponse.refreshToken,
			tokenResponse.expiresIn,
		);

		return { accessToken: tokenResponse.accessToken, expiresAt: newExpiry };
	} catch {
		return null;
	}
}

async function refreshIdCToken(
	authFile: LocalAuthFile,
): Promise<{ accessToken: string; expiresAt: Date } | null> {
	const { refreshToken, clientId, clientSecret, path: filePath } = authFile;

	if (!refreshToken || !clientId || !clientSecret) {
		return null;
	}

	try {
		const response = await fetchWithTimeout({
			url: IDC_TOKEN_ENDPOINT,
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				Host: "oidc.us-east-1.amazonaws.com",
				Connection: "keep-alive",
				"x-amz-user-agent":
					"aws-sdk-js/3.738.0 ua/2.1 os/other lang/js md/browser#unknown_unknown api/sso-oidc#3.738.0 m/E KiroIDE",
				Accept: "*/*",
				"Accept-Language": "*",
				"sec-fetch-mode": "cors",
				"User-Agent": "node",
			},
			body: JSON.stringify({
				clientId,
				clientSecret,
				grantType: "refresh_token",
				refreshToken,
			}),
		});

		if (!response.ok) {
			return null;
		}

		const tokenResponse = (await response.json()) as KiroTokenResponse;
		const newExpiry = new Date(Date.now() + tokenResponse.expiresIn * 1000);

		await persistRefreshedToken(
			filePath,
			tokenResponse.accessToken,
			tokenResponse.refreshToken,
			tokenResponse.expiresIn,
		);

		return { accessToken: tokenResponse.accessToken, expiresAt: newExpiry };
	} catch {
		return null;
	}
}

async function refreshTokenWithExpiry(
	authFile: LocalAuthFile,
): Promise<{ accessToken: string; expiresAt: Date } | null> {
	if (!authFile.refreshToken) {
		return null;
	}

	const authMethod = authFile.authMethod ?? "IdC";

	if (authMethod === "Social") {
		return refreshSocialToken(authFile.refreshToken, authFile.path);
	}
	return refreshIdCToken(authFile);
}

async function persistRefreshedToken(
	filePath: string,
	newAccessToken: string,
	newRefreshToken: string | undefined,
	expiresIn: number,
): Promise<void> {
	try {
		const file = Bun.file(filePath);
		const json = await file.json();

		json.access_token = newAccessToken;
		if (newRefreshToken) {
			json.refresh_token = newRefreshToken;
		}

		const newExpiresAt = new Date(Date.now() + expiresIn * 1000);
		json.expires_at = newExpiresAt.toISOString();
		json.last_refresh = new Date().toISOString();

		await Bun.write(filePath, JSON.stringify(json, null, 2));
	} catch {
		// Silent failure - token refresh still succeeded in memory
	}
}

async function fetchUsageAPI(
	token: string,
	tokenExpiresAt: Date | null,
): Promise<UsageAPIResult> {
	try {
		const response = await fetchWithTimeout({
			url: `${USAGE_ENDPOINT}?isEmailRequired=true&origin=AI_EDITOR`,
			headers: {
				Authorization: `Bearer ${token}`,
				"User-Agent":
					"aws-sdk-js/3.0.0 KiroIDE-0.1.0 os/macos lang/js md/nodejs/18.0.0",
				"x-amz-user-agent": "aws-sdk-js/3.0.0",
			},
		});

		if (!response.ok) {
			if (response.status === 401 || response.status === 403) {
				return { statusCode: response.status, quotaData: null };
			}

			return {
				statusCode: response.status,
				quotaData: {
					models: [
						{
							name: "Error",
							percentage: 0,
							resetTime: `HTTP ${response.status}`,
						},
					],
					lastUpdated: new Date(),
					isForbidden: false,
					planType: "Error",
					tokenExpiresAt: tokenExpiresAt ?? undefined,
				},
			};
		}

		const usageResponse = (await response.json()) as KiroUsageResponse;
		const planType =
			usageResponse.subscriptionInfo?.subscriptionTitle ?? "Standard";

		return {
			statusCode: 200,
			quotaData: convertToQuotaData(usageResponse, planType, tokenExpiresAt),
		};
	} catch (error) {
		const errorMsg = error instanceof Error ? error.message : "Unknown error";
		return {
			statusCode: 0,
			quotaData: {
				models: [{ name: "Error", percentage: 0, resetTime: errorMsg }],
				lastUpdated: new Date(),
				isForbidden: false,
				planType: "Error",
				tokenExpiresAt: tokenExpiresAt ?? undefined,
			},
		};
	}
}

function formatResetTimeFromTimestamp(timestamp?: number): string {
	if (!timestamp) return "";

	const date = new Date(timestamp * 1000);
	const month = String(date.getMonth() + 1).padStart(2, "0");
	const day = String(date.getDate()).padStart(2, "0");
	return `resets ${month}/${day}`;
}

function convertToQuotaData(
	response: KiroUsageResponse,
	planType: string,
	tokenExpiresAt: Date | null,
): ProviderQuotaData {
	const models: ModelQuota[] = [];
	const nextReset = response.nextDateReset;
	const resetTimeStr = formatResetTimeFromTimestamp(nextReset);

	if (response.usageBreakdownList) {
		for (const breakdown of response.usageBreakdownList) {
			const displayName =
				breakdown.displayName ?? breakdown.resourceType ?? "Usage";
			const hasActiveTrial =
				breakdown.freeTrialInfo?.freeTrialStatus === "ACTIVE";

			if (hasActiveTrial && breakdown.freeTrialInfo) {
				const freeTrialInfo = breakdown.freeTrialInfo;
				const used =
					freeTrialInfo.currentUsageWithPrecision ??
					freeTrialInfo.currentUsage ??
					0;
				const total =
					freeTrialInfo.usageLimitWithPrecision ??
					freeTrialInfo.usageLimit ??
					0;

				let percentage = 0;
				if (total > 0) {
					percentage = Math.max(0, ((total - used) / total) * 100);
				}

				let trialResetStr = resetTimeStr;
				if (freeTrialInfo.freeTrialExpiry) {
					const expiryDate = new Date(freeTrialInfo.freeTrialExpiry * 1000);
					const month = String(expiryDate.getMonth() + 1).padStart(2, "0");
					const day = String(expiryDate.getDate()).padStart(2, "0");
					trialResetStr = `expires ${month}/${day}`;
				}

				models.push({
					name: `Bonus ${displayName}`,
					percentage,
					resetTime: trialResetStr,
				});
			}

			const regularUsed =
				breakdown.currentUsageWithPrecision ?? breakdown.currentUsage ?? 0;
			const regularTotal =
				breakdown.usageLimitWithPrecision ?? breakdown.usageLimit ?? 0;

			if (regularTotal > 0) {
				const percentage = Math.max(
					0,
					((regularTotal - regularUsed) / regularTotal) * 100,
				);
				const quotaName = hasActiveTrial
					? `${displayName} (Base)`
					: displayName;

				models.push({
					name: quotaName,
					percentage,
					resetTime: resetTimeStr,
				});
			}
		}
	}

	if (models.length === 0) {
		models.push({
			name: "kiro-standard",
			percentage: 100,
			resetTime: "",
		});
	}

	return {
		models,
		lastUpdated: new Date(),
		isForbidden: false,
		planType,
		tokenExpiresAt: tokenExpiresAt ?? undefined,
	};
}

async function fetchQuotaForAuthFile(
	authFile: LocalAuthFile,
): Promise<ProviderQuotaData | null> {
	let currentToken = authFile.accessToken;
	if (!currentToken) return null;

	let hasAttemptedRefresh = false;
	let tokenExpiresAt = parseExpiryDate(authFile.expiresAt);

	const { shouldRefresh } = shouldRefreshToken(authFile);
	if (shouldRefresh) {
		const refreshed = await refreshTokenWithExpiry(authFile);
		if (refreshed) {
			currentToken = refreshed.accessToken;
			tokenExpiresAt = refreshed.expiresAt;
			hasAttemptedRefresh = true;
		} else {
			return {
				models: [
					{ name: "Error", percentage: 0, resetTime: "Token Refresh Failed" },
				],
				lastUpdated: new Date(),
				isForbidden: true,
				planType: "Expired",
				tokenExpiresAt: tokenExpiresAt ?? undefined,
			};
		}
	}

	const result = await fetchUsageAPI(currentToken, tokenExpiresAt);

	if (
		(result.statusCode === 401 || result.statusCode === 403) &&
		!hasAttemptedRefresh
	) {
		const refreshed = await refreshTokenWithExpiry(authFile);
		if (refreshed) {
			const retryResult = await fetchUsageAPI(
				refreshed.accessToken,
				refreshed.expiresAt,
			);
			return (
				retryResult.quotaData ?? {
					models: [],
					lastUpdated: new Date(),
					isForbidden: true,
					planType: "Unauthorized",
					tokenExpiresAt: refreshed.expiresAt,
				}
			);
		}
	}

	return result.quotaData;
}

export class KiroQuotaFetcher implements QuotaFetcher {
	readonly provider = AIProvider.KIRO;

	async fetchAll(): Promise<QuotaFetchResult[]> {
		const authFiles = await readAuthFiles("kiro-");
		if (authFiles.length === 0) return [];

		const results: QuotaFetchResult[] = [];

		for (const authFile of authFiles) {
			if (!authFile.accessToken) continue;

			const quotaData = await fetchQuotaForAuthFile(authFile);
			const accountKey = authFile.name
				.replace(/\.json$/, "")
				.replace(/^kiro-/, "");

			if (!quotaData) {
				results.push({
					account: authFile.email ?? authFile.account ?? "Kiro User",
					provider: this.provider,
					error: "Failed to fetch usage data",
				});
				continue;
			}

			results.push({
				account: accountKey,
				provider: this.provider,
				data: quotaData,
			});
		}

		return results;
	}

	async fetchForAccount(
		account: string,
		accessToken: string,
	): Promise<QuotaFetchResult> {
		const result = await fetchUsageAPI(accessToken, null);

		if (!result.quotaData) {
			return {
				account,
				provider: this.provider,
				error: "Failed to fetch usage data",
			};
		}

		return {
			account,
			provider: this.provider,
			data: result.quotaData,
		};
	}

	async refreshAllTokensIfNeeded(): Promise<number> {
		const authFiles = await readAuthFiles("kiro-");
		if (authFiles.length === 0) return 0;

		let refreshedCount = 0;

		for (const authFile of authFiles) {
			const { shouldRefresh } = shouldRefreshToken(authFile);
			if (shouldRefresh) {
				const result = await refreshTokenWithExpiry(authFile);
				if (result) {
					refreshedCount++;
				}
			}
		}

		return refreshedCount;
	}
}

export async function loadKiroDeviceRegistration(): Promise<{
	clientId: string;
	clientSecret: string;
} | null> {
	const home = process.env.HOME ?? Bun.env.HOME ?? "";
	const awsSsoPath = `${home}/.aws/sso/cache`;

	try {
		const { readdir } = await import("node:fs/promises");
		const files = await readdir(awsSsoPath);

		for (const fileName of files) {
			if (!fileName.endsWith(".json")) continue;

			const filePath = `${awsSsoPath}/${fileName}`;
			try {
				const file = Bun.file(filePath);
				const content = await file.json();

				if (content.clientId && content.clientSecret) {
					return {
						clientId: content.clientId,
						clientSecret: content.clientSecret,
					};
				}
			} catch {
				// Skip invalid JSON files
			}
		}
	} catch {
		// AWS SSO cache directory doesn't exist
	}

	return null;
}
