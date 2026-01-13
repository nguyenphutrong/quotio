import type { AIProvider } from "../models/provider.ts";
import { PROVIDER_METADATA } from "../models/provider.ts";
import type {
	ProviderQuotaData,
	QuotaFetchResult,
	QuotaFetcher,
} from "./quota-fetchers/index.ts";
import {
	AntigravityQuotaFetcher,
	ClaudeQuotaFetcher,
	CodexQuotaFetcher,
	CopilotQuotaFetcher,
	CursorQuotaFetcher,
	GeminiQuotaFetcher,
	KiroQuotaFetcher,
	TraeQuotaFetcher,
} from "./quota-fetchers/index.ts";

export type QuotaMap = Map<string, ProviderQuotaData>;

export interface QuotaServiceResult {
	quotas: QuotaMap;
	errors: Array<{ account: string; provider: AIProvider; error: string }>;
}

const FETCHER_MAP: Partial<Record<AIProvider, () => QuotaFetcher>> = {
	claude: () => new ClaudeQuotaFetcher(),
	"gemini-cli": () => new GeminiQuotaFetcher(),
	codex: () => new CodexQuotaFetcher(),
	"github-copilot": () => new CopilotQuotaFetcher(),
	cursor: () => new CursorQuotaFetcher(),
	trae: () => new TraeQuotaFetcher(),
	kiro: () => new KiroQuotaFetcher(),
	antigravity: () => new AntigravityQuotaFetcher(),
};

function getQuotaOnlyProviders(): AIProvider[] {
	return Object.entries(PROVIDER_METADATA)
		.filter(([, meta]) => meta.usesCLIQuota || meta.supportsQuotaOnlyMode)
		.map(([id]) => id as AIProvider);
}

export class QuotaService {
	private fetchers: Map<AIProvider, QuotaFetcher> = new Map();

	private getFetcher(provider: AIProvider): QuotaFetcher | null {
		const existing = this.fetchers.get(provider);
		if (existing) return existing;

		const factory = FETCHER_MAP[provider];
		if (!factory) return null;

		const fetcher = factory();
		this.fetchers.set(provider, fetcher);
		return fetcher;
	}

	async fetchAllQuotas(providers?: AIProvider[]): Promise<QuotaServiceResult> {
		const targetProviders = providers ?? getQuotaOnlyProviders();
		const quotas: QuotaMap = new Map();
		const errors: QuotaServiceResult["errors"] = [];

		const fetchPromises = targetProviders.map(async (provider) => {
			const fetcher = this.getFetcher(provider);
			if (!fetcher) return [];

			try {
				return await fetcher.fetchAll();
			} catch (err) {
				errors.push({
					account: "*",
					provider,
					error: err instanceof Error ? err.message : String(err),
				});
				return [];
			}
		});

		const allResults = await Promise.all(fetchPromises);

		for (const results of allResults) {
			for (const result of results) {
				if (result.error) {
					errors.push({
						account: result.account,
						provider: result.provider,
						error: result.error,
					});
				} else if (result.data) {
					const key = `${result.provider}:${result.account}`;
					quotas.set(key, result.data);
				}
			}
		}

		return { quotas, errors };
	}

	async fetchQuotaForProvider(
		provider: AIProvider,
	): Promise<QuotaFetchResult[]> {
		const fetcher = this.getFetcher(provider);
		if (!fetcher) return [];

		return fetcher.fetchAll();
	}

	async fetchQuotaForAccount(
		provider: AIProvider,
		account: string,
		accessToken: string,
	): Promise<QuotaFetchResult> {
		const fetcher = this.getFetcher(provider);
		if (!fetcher) {
			return {
				account,
				provider,
				error: `No fetcher available for provider: ${provider}`,
			};
		}

		return fetcher.fetchForAccount(account, accessToken);
	}
}

let sharedInstance: QuotaService | null = null;

export function getQuotaService(): QuotaService {
	if (!sharedInstance) {
		sharedInstance = new QuotaService();
	}
	return sharedInstance;
}
