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

const ANTHROPIC_USAGE_URL = "https://api.anthropic.com/api/oauth/usage";
const ANTHROPIC_BETA_HEADER = "oauth-2025-04-20";

interface QuotaUsageResponse {
	utilization: number;
	resets_at?: string;
}

interface ExtraUsageResponse {
	is_enabled: boolean;
	monthly_limit?: number;
	used_credits?: number;
	utilization?: number;
}

interface ClaudeUsageResponse {
	five_hour?: QuotaUsageResponse;
	seven_day?: QuotaUsageResponse;
	seven_day_sonnet?: QuotaUsageResponse;
	seven_day_opus?: QuotaUsageResponse;
	extra_usage?: ExtraUsageResponse;
	type?: string;
	error?: { type: string; message?: string };
}

type FetchResult =
	| { status: "success"; data: ClaudeUsageResponse }
	| { status: "auth_error" }
	| { status: "error"; message: string };

async function fetchUsageFromAPI(accessToken: string): Promise<FetchResult> {
	try {
		const response = await fetchWithTimeout({
			url: ANTHROPIC_USAGE_URL,
			headers: {
				Accept: "application/json",
				Authorization: `Bearer ${accessToken}`,
				"anthropic-beta": ANTHROPIC_BETA_HEADER,
			},
		});

		if (response.status === 401) {
			return { status: "auth_error" };
		}

		if (!response.ok) {
			return { status: "error", message: `HTTP ${response.status}` };
		}

		const json = (await response.json()) as ClaudeUsageResponse;

		if (json.type === "error") {
			if (json.error?.type === "authentication_error") {
				return { status: "auth_error" };
			}
			return { status: "error", message: json.error?.message ?? "API error" };
		}

		return { status: "success", data: json };
	} catch (err) {
		return {
			status: "error",
			message: err instanceof Error ? err.message : String(err),
		};
	}
}

function parseQuotaUsageToModel(
	name: string,
	usage: QuotaUsageResponse | undefined,
): ModelQuota | null {
	if (!usage) return null;

	const remaining = Math.max(0, Math.min(100, 100 - usage.utilization));
	return {
		name,
		percentage: remaining,
		resetTime: usage.resets_at ?? "",
	};
}

function convertToProviderQuota(data: ClaudeUsageResponse): ProviderQuotaData {
	const models: ModelQuota[] = [];

	const fiveHour = parseQuotaUsageToModel("five-hour-session", data.five_hour);
	if (fiveHour) models.push(fiveHour);

	const sevenDay = parseQuotaUsageToModel("seven-day-weekly", data.seven_day);
	if (sevenDay) models.push(sevenDay);

	const sonnet = parseQuotaUsageToModel(
		"seven-day-sonnet",
		data.seven_day_sonnet,
	);
	if (sonnet) models.push(sonnet);

	const opus = parseQuotaUsageToModel("seven-day-opus", data.seven_day_opus);
	if (opus) models.push(opus);

	const extra = data.extra_usage;
	if (extra?.is_enabled && extra.utilization !== undefined) {
		const remaining = Math.max(0, Math.min(100, 100 - extra.utilization));
		const model: ModelQuota = {
			name: "extra-usage",
			percentage: remaining,
			resetTime: "",
		};
		if (extra.used_credits !== undefined) {
			model.used = Math.floor(extra.used_credits);
		}
		if (extra.monthly_limit !== undefined) {
			model.limit = Math.floor(extra.monthly_limit);
		}
		models.push(model);
	}

	return {
		models,
		lastUpdated: new Date(),
		isForbidden: false,
	};
}

export class ClaudeQuotaFetcher implements QuotaFetcher {
	readonly provider = AIProvider.CLAUDE;

	async fetchAll(): Promise<QuotaFetchResult[]> {
		const authFiles = await readAuthFiles("claude-");
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
		const { accessToken, email } = file;
		if (!accessToken || !email) return null;

		return this.fetchForAccount(email, accessToken);
	}
}
