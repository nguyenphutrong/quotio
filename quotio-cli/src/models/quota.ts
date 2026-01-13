export interface ModelQuota {
	name: string;
	percentage: number;
	resetTime: string;
	used?: number;
	limit?: number;
	remaining?: number;
}

export interface ProviderQuotaData {
	models: ModelQuota[];
	lastUpdated: Date;
	isForbidden: boolean;
	planType?: string;
	/** Token expiry time for providers that support token refresh (e.g., Kiro) */
	tokenExpiresAt?: Date;
}

export type QuotaMap = Record<string, ProviderQuotaData>;

export interface UsageData {
	totalRequests?: number;
	successCount?: number;
	failureCount?: number;
	totalTokens?: number;
	inputTokens?: number;
	outputTokens?: number;
}

export interface UsageStats {
	usage?: UsageData;
	failedRequests?: number;
}

export function parseUsageStats(json: Record<string, unknown>): UsageStats {
	const usage = json.usage as Record<string, unknown> | undefined;
	return {
		usage: usage
			? {
					totalRequests: usage.total_requests as number | undefined,
					successCount: usage.success_count as number | undefined,
					failureCount: usage.failure_count as number | undefined,
					totalTokens: usage.total_tokens as number | undefined,
					inputTokens: usage.input_tokens as number | undefined,
					outputTokens: usage.output_tokens as number | undefined,
				}
			: undefined,
		failedRequests: json.failed_requests as number | undefined,
	};
}

export function calculateSuccessRate(usage: UsageData): number {
	const total = usage.totalRequests ?? 0;
	const success = usage.successCount ?? 0;
	if (total === 0) return 0;
	return (success / total) * 100;
}

export function formatCompactNumber(num: number): string {
	if (num >= 1_000_000) {
		return `${(num / 1_000_000).toFixed(1)}M`;
	}
	if (num >= 1_000) {
		return `${(num / 1_000).toFixed(1)}K`;
	}
	return String(num);
}

export function createEmptyQuotaData(): ProviderQuotaData {
	return {
		models: [],
		lastUpdated: new Date(),
		isForbidden: false,
	};
}
