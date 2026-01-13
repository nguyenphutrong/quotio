import { AIProvider } from "../../models/provider.ts";
import type {
	ModelQuota,
	ProviderQuotaData,
	QuotaFetchResult,
	QuotaFetcher,
} from "./types.ts";
import { decodeJWTPayload } from "./types.ts";

const GEMINI_AUTH_PATH = "~/.gemini/oauth_creds.json";
const GEMINI_ACCOUNTS_PATH = "~/.gemini/google_accounts.json";

interface GeminiAuthFile {
	id_token?: string;
	access_token?: string;
	refresh_token?: string;
	expiry_date?: number;
}

interface GeminiAccountsFile {
	active?: string;
	old?: string[];
}

interface JWTClaims {
	email?: string;
	name?: string;
	sub?: string;
}

function expandTildePath(path: string): string {
	const home = process.env.HOME ?? Bun.env.HOME ?? "";
	return path.replace(/^~/, home);
}

async function readJsonFile<T>(path: string): Promise<T | null> {
	try {
		const expandedPath = expandTildePath(path);
		const file = Bun.file(expandedPath);
		if (!(await file.exists())) return null;
		return (await file.json()) as T;
	} catch {
		return null;
	}
}

export class GeminiQuotaFetcher implements QuotaFetcher {
	readonly provider = AIProvider.GEMINI;

	async fetchAll(): Promise<QuotaFetchResult[]> {
		const authFile = await readJsonFile<GeminiAuthFile>(GEMINI_AUTH_PATH);
		if (!authFile) return [];

		let email: string | undefined;
		let name: string | undefined;

		const accountsFile =
			await readJsonFile<GeminiAccountsFile>(GEMINI_ACCOUNTS_PATH);
		email = accountsFile?.active;

		if (!email && authFile.id_token) {
			const claims = decodeJWTPayload<JWTClaims>(authFile.id_token);
			email = claims?.email;
			name = claims?.name;
		}

		if (!email) return [];

		const models: ModelQuota[] = [
			{
				name: "gemini-quota",
				percentage: -1,
				resetTime: "",
			},
		];

		const data: ProviderQuotaData = {
			models,
			lastUpdated: new Date(),
			isForbidden: false,
			planType: name ?? "Google Account",
		};

		return [
			{
				account: email,
				provider: this.provider,
				data,
			},
		];
	}

	async fetchForAccount(
		account: string,
		_accessToken: string,
	): Promise<QuotaFetchResult> {
		const results = await this.fetchAll();
		const found = results.find((r) => r.account === account);
		return (
			found ?? {
				account,
				provider: this.provider,
				error: "Account not found in local Gemini auth files",
			}
		);
	}
}
