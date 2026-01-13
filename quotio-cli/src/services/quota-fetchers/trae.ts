import { AIProvider } from "../../models/provider.ts";
import type {
	ModelQuota,
	ProviderQuotaData,
	QuotaFetchResult,
	QuotaFetcher,
} from "./types.ts";
import { fetchWithTimeout } from "./types.ts";

const STORAGE_JSON_PATH =
	"~/Library/Application Support/Trae/User/globalStorage/storage.json";
const AUTH_KEY = "iCubeAuthInfo://icube.cloudide";

interface TraeAuthData {
	accessToken?: string;
	refreshToken?: string;
	email?: string;
	userId?: string;
	apiHost?: string;
	username?: string;
}

interface EntitlementBaseInfo {
	end_time?: number;
	product_type?: number;
	quota?: {
		advanced_model_request_limit?: number;
		auto_completion_limit?: number;
		premium_model_fast_request_limit?: number;
		premium_model_slow_request_limit?: number;
	};
}

interface EntitlementUsage {
	advanced_model_amount?: number;
	auto_completion_amount?: number;
	premium_model_fast_amount?: number;
	premium_model_slow_amount?: number;
}

interface UserEntitlement {
	status?: number;
	entitlement_base_info?: EntitlementBaseInfo;
	usage?: EntitlementUsage;
}

interface EntitlementListResponse {
	user_entitlement_pack_list?: UserEntitlement[];
}

function expandPath(path: string): string {
	const home = process.env.HOME ?? Bun.env.HOME ?? "";
	return path.replace(/^~/, home);
}

function isInstalled(): boolean {
	const appPaths = [
		"/Applications/Trae.app",
		expandPath("~/Applications/Trae.app"),
	];

	for (const path of appPaths) {
		if (Bun.spawnSync(["test", "-d", path]).exitCode === 0) {
			return true;
		}
	}

	return false;
}

async function readAuthFromStorageJson(): Promise<TraeAuthData | null> {
	const filePath = expandPath(STORAGE_JSON_PATH);

	try {
		const file = Bun.file(filePath);
		if (!(await file.exists())) {
			return null;
		}

		const storageJson = await file.json();
		const authInfoString = storageJson[AUTH_KEY];

		if (!authInfoString || typeof authInfoString !== "string") {
			return null;
		}

		const authInfo = JSON.parse(authInfoString);

		const authData: TraeAuthData = {
			accessToken: authInfo.token,
			refreshToken: authInfo.refreshToken,
			userId: authInfo.userId,
			apiHost: authInfo.host,
		};

		if (authInfo.account) {
			authData.email = authInfo.account.email;
			authData.username = authInfo.account.username;
		}

		if (!authData.accessToken && !authData.email) {
			return null;
		}

		return authData;
	} catch {
		return null;
	}
}

function getPlanTypeName(productType?: number): string | undefined {
	switch (productType) {
		case 0:
			return "Free";
		case 1:
			return "Pro";
		case 2:
			return "Team";
		case 3:
			return "Builder";
		default:
			return undefined;
	}
}

async function fetchEntitlementList(
	accessToken: string,
	apiHost: string,
): Promise<EntitlementListResponse | null> {
	try {
		const response = await fetchWithTimeout({
			url: `${apiHost}/trae/api/v1/pay/user_current_entitlement_list`,
			method: "POST",
			headers: {
				Authorization: `Cloud-IDE-JWT ${accessToken}`,
				"Content-Type": "application/json",
				Accept: "application/json, text/plain, */*",
				Origin: "https://www.trae.ai",
				Referer: "https://www.trae.ai/",
			},
			body: JSON.stringify({ require_usage: true }),
		});

		if (!response.ok) {
			return null;
		}

		return (await response.json()) as EntitlementListResponse;
	} catch {
		return null;
	}
}

function convertToProviderQuota(
	authData: TraeAuthData,
	entitlement: UserEntitlement | null,
	resetTime: Date | null,
): ProviderQuotaData {
	const models: ModelQuota[] = [];

	const resetTimeStr = resetTime ? resetTime.toISOString() : "";
	const quota = entitlement?.entitlement_base_info?.quota;
	const usage = entitlement?.usage;

	if (
		quota?.premium_model_fast_request_limit &&
		quota.premium_model_fast_request_limit > 0
	) {
		const used = usage?.premium_model_fast_amount ?? 0;
		const limit = quota.premium_model_fast_request_limit;
		const remaining = Math.max(0, limit - used);
		const percentage = (remaining / limit) * 100;

		models.push({
			name: "premium-fast",
			percentage,
			resetTime: resetTimeStr,
			used,
			limit,
			remaining,
		});
	}

	if (
		quota?.premium_model_slow_request_limit &&
		quota.premium_model_slow_request_limit > 0
	) {
		const used = usage?.premium_model_slow_amount ?? 0;
		const limit = quota.premium_model_slow_request_limit;
		const remaining = Math.max(0, limit - used);
		const percentage = (remaining / limit) * 100;

		models.push({
			name: "premium-slow",
			percentage,
			resetTime: resetTimeStr,
			used,
			limit,
			remaining,
		});
	}

	if (
		quota?.advanced_model_request_limit &&
		quota.advanced_model_request_limit > 0
	) {
		const used = usage?.advanced_model_amount ?? 0;
		const limit = quota.advanced_model_request_limit;
		const remaining = Math.max(0, limit - used);
		const percentage = (remaining / limit) * 100;

		models.push({
			name: "advanced-model",
			percentage,
			resetTime: resetTimeStr,
			used,
			limit,
			remaining,
		});
	}

	if (quota?.auto_completion_limit && quota.auto_completion_limit > 0) {
		const used = usage?.auto_completion_amount ?? 0;
		const limit = quota.auto_completion_limit;
		const remaining = Math.max(0, limit - used);
		const percentage = (remaining / limit) * 100;

		models.push({
			name: "auto-completion",
			percentage,
			resetTime: resetTimeStr,
			used,
			limit,
			remaining,
		});
	}

	if (models.length === 0) {
		models.push({
			name: "trae-usage",
			percentage: -1,
			resetTime: "",
		});
	}

	return {
		models,
		lastUpdated: new Date(),
		isForbidden: false,
		planType: getPlanTypeName(entitlement?.entitlement_base_info?.product_type),
	};
}

export class TraeQuotaFetcher implements QuotaFetcher {
	readonly provider = AIProvider.TRAE;

	async fetchAll(): Promise<QuotaFetchResult[]> {
		if (!isInstalled()) {
			return [];
		}

		const authData = await readAuthFromStorageJson();
		if (!authData?.accessToken) {
			return [];
		}

		const apiHost = authData.apiHost ?? "https://api-sg-central.trae.ai";
		const entitlementResponse = await fetchEntitlementList(
			authData.accessToken,
			apiHost,
		);

		let activeEntitlement: UserEntitlement | null = null;
		let resetTime: Date | null = null;

		const entitlementList =
			entitlementResponse?.user_entitlement_pack_list ?? [];
		for (const entitlement of entitlementList) {
			if (entitlement.status === 1) {
				activeEntitlement = entitlement;
				const endTimestamp = entitlement.entitlement_base_info?.end_time;
				if (endTimestamp) {
					resetTime = new Date(endTimestamp * 1000);
				}
				break;
			}
		}

		if (!activeEntitlement && entitlementList.length > 0) {
			activeEntitlement = entitlementList[0] ?? null;
		}

		const quotaData = convertToProviderQuota(
			authData,
			activeEntitlement,
			resetTime,
		);
		const email =
			authData.email ?? authData.username ?? authData.userId ?? "Trae User";

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
		const apiHost = "https://api-sg-central.trae.ai";
		const entitlementResponse = await fetchEntitlementList(
			accessToken,
			apiHost,
		);

		if (!entitlementResponse) {
			return {
				account,
				provider: this.provider,
				error: "Failed to fetch entitlement data",
			};
		}

		let activeEntitlement: UserEntitlement | null = null;
		let resetTime: Date | null = null;

		const entitlementList =
			entitlementResponse.user_entitlement_pack_list ?? [];
		for (const entitlement of entitlementList) {
			if (entitlement.status === 1) {
				activeEntitlement = entitlement;
				const endTimestamp = entitlement.entitlement_base_info?.end_time;
				if (endTimestamp) {
					resetTime = new Date(endTimestamp * 1000);
				}
				break;
			}
		}

		const quotaData = convertToProviderQuota(
			{ email: account },
			activeEntitlement,
			resetTime,
		);

		return {
			account,
			provider: this.provider,
			data: quotaData,
		};
	}
}
