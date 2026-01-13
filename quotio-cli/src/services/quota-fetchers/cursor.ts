import { Database } from "bun:sqlite";
import { AIProvider } from "../../models/provider.ts";
import type {
	ModelQuota,
	ProviderQuotaData,
	QuotaFetchResult,
	QuotaFetcher,
} from "./types.ts";
import { createEmptyQuotaData, fetchWithTimeout } from "./types.ts";

const CURSOR_API_BASE = "https://api2.cursor.sh";
const STATE_DB_PATH =
	"~/Library/Application Support/Cursor/User/globalStorage/state.vscdb";

interface CursorAuthData {
	accessToken?: string;
	refreshToken?: string;
	email?: string;
	membershipType?: string;
	subscriptionStatus?: string;
	signUpType?: string;
}

interface PlanUsage {
	enabled: boolean;
	used: number;
	limit: number;
	remaining: number;
	totalPercentUsed: number;
	autoPercentUsed: number;
	apiPercentUsed: number;
}

interface OnDemandUsage {
	enabled: boolean;
	used: number;
	limit?: number;
	remaining?: number;
}

interface UsageSummaryResponse {
	membershipType?: string;
	isUnlimited?: boolean;
	billingCycleStart?: string;
	billingCycleEnd?: string;
	individualUsage?: {
		plan?: PlanUsage;
		onDemand?: OnDemandUsage;
	};
}

function expandPath(path: string): string {
	const home = process.env.HOME ?? Bun.env.HOME ?? "";
	return path.replace(/^~/, home);
}

function isInstalled(): boolean {
	const appPaths = [
		"/Applications/Cursor.app",
		expandPath("~/Applications/Cursor.app"),
	];

	for (const path of appPaths) {
		try {
			if (Bun.spawnSync(["test", "-d", path]).exitCode === 0) {
				return true;
			}
		} catch {
			// Path check failed, try next
		}
	}

	return false;
}

function readAuthFromStateDB(): CursorAuthData | null {
	const dbPath = expandPath(STATE_DB_PATH);

	try {
		if (Bun.spawnSync(["test", "-f", dbPath]).exitCode !== 0) {
			return null;
		}

		// SQLite opened with readonly to avoid WAL file requirement when Cursor is not running
		const db = new Database(dbPath, { readonly: true });

		try {
			const query = db.query(
				"SELECT key, value FROM ItemTable WHERE key LIKE 'cursorAuth/%'",
			);
			const rows = query.all() as { key: string; value: string }[];

			const authData: CursorAuthData = {};

			for (const row of rows) {
				switch (row.key) {
					case "cursorAuth/accessToken":
						authData.accessToken = row.value;
						break;
					case "cursorAuth/refreshToken":
						authData.refreshToken = row.value;
						break;
					case "cursorAuth/cachedEmail":
						authData.email = row.value;
						break;
					case "cursorAuth/stripeMembershipType":
						authData.membershipType = row.value;
						break;
					case "cursorAuth/stripeSubscriptionStatus":
						authData.subscriptionStatus = row.value;
						break;
					case "cursorAuth/cachedSignUpType":
						authData.signUpType = row.value;
						break;
				}
			}

			if (!authData.accessToken && !authData.email) {
				return null;
			}

			return authData;
		} finally {
			db.close();
		}
	} catch {
		return null;
	}
}

async function fetchUsageSummary(
	accessToken: string,
): Promise<UsageSummaryResponse | null> {
	try {
		const response = await fetchWithTimeout({
			url: `${CURSOR_API_BASE}/auth/usage-summary`,
			headers: {
				Authorization: `Bearer ${accessToken}`,
				Accept: "application/json",
				"User-Agent":
					"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
			},
		});

		if (!response.ok) {
			return null;
		}

		return (await response.json()) as UsageSummaryResponse;
	} catch {
		return null;
	}
}

function formatPlanType(membership?: string): string | undefined {
	if (!membership) return undefined;

	return membership
		.replace(/_/g, " ")
		.split(" ")
		.map((word) => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase())
		.join(" ");
}

function convertToProviderQuota(
	authData: CursorAuthData,
	response: UsageSummaryResponse | null,
): ProviderQuotaData {
	const models: ModelQuota[] = [];

	const billingCycleEnd = response?.billingCycleEnd ?? "";
	const resetTimeStr = billingCycleEnd
		? new Date(billingCycleEnd).toISOString()
		: "";

	const plan = response?.individualUsage?.plan;
	if (plan?.enabled) {
		const remaining = plan.remaining ?? 0;
		const limit = plan.limit ?? 0;
		const percentage = limit > 0 ? (remaining / limit) * 100 : 100;

		const planModel: ModelQuota = {
			name: "plan-usage",
			percentage,
			resetTime: resetTimeStr,
			used: plan.used,
			limit: plan.limit,
			remaining: plan.remaining,
		};
		models.push(planModel);
	}

	const onDemand = response?.individualUsage?.onDemand;
	if (onDemand?.enabled) {
		let percentage: number;
		if (
			onDemand.limit &&
			onDemand.limit > 0 &&
			onDemand.remaining !== undefined
		) {
			percentage = (onDemand.remaining / onDemand.limit) * 100;
		} else {
			percentage = 100;
		}

		const onDemandModel: ModelQuota = {
			name: "on-demand",
			percentage,
			resetTime: "",
			used: onDemand.used,
			limit: onDemand.limit,
			remaining: onDemand.remaining,
		};
		models.push(onDemandModel);
	}

	if (models.length === 0) {
		models.push({
			name: "cursor-usage",
			percentage: response?.isUnlimited ? 100 : -1,
			resetTime: "",
		});
	}

	return {
		models,
		lastUpdated: new Date(),
		isForbidden: false,
		planType: formatPlanType(
			response?.membershipType ?? authData.membershipType,
		),
	};
}

export class CursorQuotaFetcher implements QuotaFetcher {
	readonly provider = AIProvider.CURSOR;

	async fetchAll(): Promise<QuotaFetchResult[]> {
		if (!isInstalled()) {
			return [];
		}

		const authData = readAuthFromStateDB();
		if (!authData?.accessToken) {
			return [];
		}

		const email = authData.email ?? "Cursor User";
		const usageResponse = await fetchUsageSummary(authData.accessToken);

		const quotaData = convertToProviderQuota(authData, usageResponse);

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
		const usageResponse = await fetchUsageSummary(accessToken);

		if (!usageResponse) {
			return {
				account,
				provider: this.provider,
				error: "Failed to fetch usage data",
			};
		}

		const quotaData = convertToProviderQuota({ email: account }, usageResponse);

		return {
			account,
			provider: this.provider,
			data: quotaData,
		};
	}
}
