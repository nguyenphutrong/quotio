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
	readAuthFiles,
} from "./types.ts";

const ENTITLEMENT_URL = "https://api.github.com/copilot_internal/user";

interface QuotaSnapshot {
	entitlement?: number;
	remaining?: number;
	percent_remaining?: number;
	overage_count?: number;
	overage_permitted?: boolean;
	unlimited?: boolean;
}

interface QuotaSnapshots {
	chat?: QuotaSnapshot;
	completions?: QuotaSnapshot;
	premium_interactions?: QuotaSnapshot;
}

interface LimitedUserQuotas {
	chat?: number;
	completions?: number;
}

interface MonthlyQuotas {
	chat?: number;
	completions?: number;
}

interface CopilotEntitlement {
	access_type_sku?: string;
	copilot_plan?: string;
	chat_enabled?: boolean;
	quota_reset_date?: string;
	quota_reset_date_utc?: string;
	limited_user_reset_date?: string;
	quota_snapshots?: QuotaSnapshots;
	limited_user_quotas?: LimitedUserQuotas;
	monthly_quotas?: MonthlyQuotas;
}

type FetchResult =
	| { status: "success"; data: CopilotEntitlement }
	| { status: "forbidden" }
	| { status: "error"; message: string };

function calculateSnapshotPercent(
	snapshot: QuotaSnapshot | undefined,
	defaultTotal: number,
): number {
	if (!snapshot) return -1;
	if (snapshot.percent_remaining !== undefined) {
		return snapshot.percent_remaining;
	}
	const remaining = snapshot.remaining ?? 0;
	const total = snapshot.entitlement ?? defaultTotal;
	return total > 0 ? (remaining / total) * 100 : 0;
}

function getPlanDisplayName(entitlement: CopilotEntitlement): string {
	const sku = (entitlement.access_type_sku ?? "").toLowerCase();
	const plan = (entitlement.copilot_plan ?? "").toLowerCase();

	if (sku.includes("free")) return "Free";
	if (sku.includes("enterprise") || plan === "enterprise") return "Enterprise";
	if (sku.includes("business") || plan === "business") return "Business";
	if (sku.includes("pro") || plan.includes("pro")) return "Pro";
	if (plan === "individual" || sku.includes("individual")) return "Pro";
	if (plan.includes("free")) return "Free";

	return entitlement.copilot_plan ?? entitlement.access_type_sku ?? "Unknown";
}

function getResetDate(entitlement: CopilotEntitlement): string {
	const dateStr =
		entitlement.quota_reset_date_utc ??
		entitlement.quota_reset_date ??
		entitlement.limited_user_reset_date;

	if (!dateStr) return "";

	try {
		const date = new Date(dateStr);
		return date.toISOString();
	} catch {
		return dateStr;
	}
}

async function fetchEntitlement(accessToken: string): Promise<FetchResult> {
	try {
		const response = await fetchWithTimeout({
			url: ENTITLEMENT_URL,
			headers: {
				Authorization: `Bearer ${accessToken}`,
				Accept: "application/vnd.github+json",
				"X-GitHub-Api-Version": "2022-11-28",
			},
		});

		if (response.status === 401 || response.status === 403) {
			return { status: "forbidden" };
		}

		if (!response.ok) {
			return { status: "error", message: `HTTP ${response.status}` };
		}

		const json = (await response.json()) as CopilotEntitlement;
		return { status: "success", data: json };
	} catch (err) {
		return {
			status: "error",
			message: err instanceof Error ? err.message : String(err),
		};
	}
}

function convertToProviderQuota(
	entitlement: CopilotEntitlement,
): ProviderQuotaData {
	const models: ModelQuota[] = [];
	const resetTimeString = getResetDate(entitlement);

	const snapshots = entitlement.quota_snapshots;
	if (snapshots) {
		if (snapshots.chat && snapshots.chat.unlimited !== true) {
			models.push({
				name: "copilot-chat",
				percentage: calculateSnapshotPercent(snapshots.chat, 50),
				resetTime: resetTimeString,
			});
		}

		if (snapshots.completions && snapshots.completions.unlimited !== true) {
			models.push({
				name: "copilot-completions",
				percentage: calculateSnapshotPercent(snapshots.completions, 2000),
				resetTime: resetTimeString,
			});
		}

		if (
			snapshots.premium_interactions &&
			snapshots.premium_interactions.unlimited !== true
		) {
			models.push({
				name: "copilot-premium",
				percentage: calculateSnapshotPercent(
					snapshots.premium_interactions,
					50,
				),
				resetTime: resetTimeString,
			});
		}
	}

	if (models.length === 0) {
		const remaining = entitlement.limited_user_quotas;
		const total = entitlement.monthly_quotas;

		if (remaining && total) {
			if (remaining.chat !== undefined && total.chat && total.chat > 0) {
				const percentage = (remaining.chat / total.chat) * 100;
				models.push({
					name: "copilot-chat",
					percentage,
					resetTime: resetTimeString,
				});
			}

			if (
				remaining.completions !== undefined &&
				total.completions &&
				total.completions > 0
			) {
				const percentage = (remaining.completions / total.completions) * 100;
				models.push({
					name: "copilot-completions",
					percentage,
					resetTime: resetTimeString,
				});
			}
		}
	}

	return {
		models,
		lastUpdated: new Date(),
		isForbidden: false,
		planType: getPlanDisplayName(entitlement),
	};
}

function extractUsername(filename: string): string {
	let name = filename;
	if (name.startsWith("github-copilot-")) {
		name = name.slice("github-copilot-".length);
	}
	if (name.endsWith(".json")) {
		name = name.slice(0, -".json".length);
	}
	return name;
}

export class CopilotQuotaFetcher implements QuotaFetcher {
	readonly provider = AIProvider.COPILOT;

	async fetchAll(): Promise<QuotaFetchResult[]> {
		const authFiles = await readAuthFiles("github-copilot-");
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
		const result = await fetchEntitlement(accessToken);

		if (result.status === "forbidden") {
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
		const { accessToken, account } = file;
		if (!accessToken) return null;

		const username = account ?? extractUsername(file.name);
		return this.fetchForAccount(username, accessToken);
	}
}
