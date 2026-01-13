/**
 * Request Log model - mirrors Swift RequestLog.swift for cross-platform compatibility.
 */

export interface RequestLog {
	id: string;
	timestamp: string;
	method: string;
	endpoint: string;
	provider: string | null;
	model: string | null;
	inputTokens: number | null;
	outputTokens: number | null;
	durationMs: number;
	statusCode: number | null;
	requestSize: number;
	responseSize: number;
	errorMessage: string | null;
}

export function createRequestLog(
	data: Omit<RequestLog, "id" | "timestamp">,
): RequestLog {
	return {
		id: crypto.randomUUID(),
		timestamp: new Date().toISOString(),
		...data,
	};
}

export function isSuccessfulRequest(log: RequestLog): boolean {
	const code = log.statusCode;
	if (code === null) return false;
	return code >= 200 && code < 300;
}

export function getTotalTokens(log: RequestLog): number | null {
	if (log.inputTokens === null && log.outputTokens === null) return null;
	return (log.inputTokens ?? 0) + (log.outputTokens ?? 0);
}

export interface ProviderStats {
	provider: string;
	requestCount: number;
	inputTokens: number;
	outputTokens: number;
	averageDurationMs: number;
}

export interface ModelStats {
	model: string;
	provider: string | null;
	requestCount: number;
	inputTokens: number;
	outputTokens: number;
	averageDurationMs: number;
}

export interface RequestStats {
	totalRequests: number;
	successfulRequests: number;
	failedRequests: number;
	totalInputTokens: number;
	totalOutputTokens: number;
	averageDurationMs: number;
	byProvider: Record<string, ProviderStats>;
	byModel: Record<string, ModelStats>;
}

export function createEmptyStats(): RequestStats {
	return {
		totalRequests: 0,
		successfulRequests: 0,
		failedRequests: 0,
		totalInputTokens: 0,
		totalOutputTokens: 0,
		averageDurationMs: 0,
		byProvider: {},
		byModel: {},
	};
}

export function getSuccessRate(stats: RequestStats): number {
	if (stats.totalRequests === 0) return 0;
	return (stats.successfulRequests / stats.totalRequests) * 100;
}

export function getStatsTotalTokens(stats: RequestStats): number {
	return stats.totalInputTokens + stats.totalOutputTokens;
}

export interface RequestHistoryStore {
	version: number;
	entries: RequestLog[];
}

export const MAX_ENTRIES = 50;
export const CURRENT_VERSION = 1;

export function createEmptyStore(): RequestHistoryStore {
	return { version: CURRENT_VERSION, entries: [] };
}

export function addEntryToStore(
	store: RequestHistoryStore,
	entry: RequestLog,
): RequestHistoryStore {
	const newEntries = [entry, ...store.entries];
	if (newEntries.length > MAX_ENTRIES) {
		newEntries.length = MAX_ENTRIES;
	}
	return { ...store, entries: newEntries };
}

export function calculateStats(entries: RequestLog[]): RequestStats {
	if (entries.length === 0) return createEmptyStats();

	let totalInput = 0;
	let totalOutput = 0;
	let totalDuration = 0;
	let successCount = 0;

	const providerData: Record<
		string,
		{ count: number; input: number; output: number; duration: number }
	> = {};
	const modelData: Record<
		string,
		{
			provider: string | null;
			count: number;
			input: number;
			output: number;
			duration: number;
		}
	> = {};

	for (const entry of entries) {
		totalInput += entry.inputTokens ?? 0;
		totalOutput += entry.outputTokens ?? 0;
		totalDuration += entry.durationMs;

		if (isSuccessfulRequest(entry)) {
			successCount++;
		}

		if (entry.provider) {
			const existing = providerData[entry.provider] ?? {
				count: 0,
				input: 0,
				output: 0,
				duration: 0,
			};
			existing.count++;
			existing.input += entry.inputTokens ?? 0;
			existing.output += entry.outputTokens ?? 0;
			existing.duration += entry.durationMs;
			providerData[entry.provider] = existing;
		}

		if (entry.model) {
			const existing = modelData[entry.model] ?? {
				provider: entry.provider,
				count: 0,
				input: 0,
				output: 0,
				duration: 0,
			};
			existing.count++;
			existing.input += entry.inputTokens ?? 0;
			existing.output += entry.outputTokens ?? 0;
			existing.duration += entry.durationMs;
			modelData[entry.model] = existing;
		}
	}

	const byProvider: Record<string, ProviderStats> = {};
	for (const [key, data] of Object.entries(providerData)) {
		byProvider[key] = {
			provider: key,
			requestCount: data.count,
			inputTokens: data.input,
			outputTokens: data.output,
			averageDurationMs:
				data.count > 0 ? Math.round(data.duration / data.count) : 0,
		};
	}

	const byModel: Record<string, ModelStats> = {};
	for (const [key, data] of Object.entries(modelData)) {
		byModel[key] = {
			model: key,
			provider: data.provider,
			requestCount: data.count,
			inputTokens: data.input,
			outputTokens: data.output,
			averageDurationMs:
				data.count > 0 ? Math.round(data.duration / data.count) : 0,
		};
	}

	return {
		totalRequests: entries.length,
		successfulRequests: successCount,
		failedRequests: entries.length - successCount,
		totalInputTokens: totalInput,
		totalOutputTokens: totalOutput,
		averageDurationMs:
			entries.length > 0 ? Math.round(totalDuration / entries.length) : 0,
		byProvider,
		byModel,
	};
}
