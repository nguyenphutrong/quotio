export enum AIProvider {
	GEMINI = "gemini-cli",
	CLAUDE = "claude",
	CODEX = "codex",
	QWEN = "qwen",
	IFLOW = "iflow",
	ANTIGRAVITY = "antigravity",
	VERTEX = "vertex",
	KIRO = "kiro",
	COPILOT = "github-copilot",
	CURSOR = "cursor",
	TRAE = "trae",
	GLM = "glm",
}

export interface ProviderMetadata {
	id: AIProvider;
	displayName: string;
	color: string;
	oauthEndpoint: string | null;
	supportsQuotaOnlyMode: boolean;
	usesBrowserAuth: boolean;
	usesCLIQuota: boolean;
	supportsManualAuth: boolean;
	usesAPIKeyAuth: boolean;
	isQuotaTrackingOnly: boolean;
	menuBarSymbol: string;
	logoAssetName: string;
	iconName: string;
}

export const PROVIDER_METADATA: Record<AIProvider, ProviderMetadata> = {
	[AIProvider.GEMINI]: {
		id: AIProvider.GEMINI,
		displayName: "Gemini CLI",
		color: "#4285F4",
		oauthEndpoint: "/gemini-cli-auth-url",
		supportsQuotaOnlyMode: true,
		usesBrowserAuth: false,
		usesCLIQuota: true,
		supportsManualAuth: true,
		usesAPIKeyAuth: false,
		isQuotaTrackingOnly: false,
		menuBarSymbol: "G",
		logoAssetName: "gemini",
		iconName: "sparkles",
	},
	[AIProvider.CLAUDE]: {
		id: AIProvider.CLAUDE,
		displayName: "Claude Code",
		color: "#D97706",
		oauthEndpoint: "/anthropic-auth-url",
		supportsQuotaOnlyMode: true,
		usesBrowserAuth: false,
		usesCLIQuota: true,
		supportsManualAuth: true,
		usesAPIKeyAuth: false,
		isQuotaTrackingOnly: false,
		menuBarSymbol: "C",
		logoAssetName: "claude",
		iconName: "brain.head.profile",
	},
	[AIProvider.CODEX]: {
		id: AIProvider.CODEX,
		displayName: "Codex (OpenAI)",
		color: "#10A37F",
		oauthEndpoint: "/codex-auth-url",
		supportsQuotaOnlyMode: true,
		usesBrowserAuth: false,
		usesCLIQuota: true,
		supportsManualAuth: true,
		usesAPIKeyAuth: false,
		isQuotaTrackingOnly: false,
		menuBarSymbol: "O",
		logoAssetName: "openai",
		iconName: "chevron.left.forwardslash.chevron.right",
	},
	[AIProvider.QWEN]: {
		id: AIProvider.QWEN,
		displayName: "Qwen Code",
		color: "#7C3AED",
		oauthEndpoint: "/qwen-auth-url",
		supportsQuotaOnlyMode: false,
		usesBrowserAuth: false,
		usesCLIQuota: false,
		supportsManualAuth: true,
		usesAPIKeyAuth: false,
		isQuotaTrackingOnly: false,
		menuBarSymbol: "Q",
		logoAssetName: "qwen",
		iconName: "cloud",
	},
	[AIProvider.IFLOW]: {
		id: AIProvider.IFLOW,
		displayName: "iFlow",
		color: "#06B6D4",
		oauthEndpoint: "/iflow-auth-url",
		supportsQuotaOnlyMode: false,
		usesBrowserAuth: false,
		usesCLIQuota: false,
		supportsManualAuth: true,
		usesAPIKeyAuth: false,
		isQuotaTrackingOnly: false,
		menuBarSymbol: "F",
		logoAssetName: "iflow",
		iconName: "arrow.triangle.branch",
	},
	[AIProvider.ANTIGRAVITY]: {
		id: AIProvider.ANTIGRAVITY,
		displayName: "Antigravity",
		color: "#EC4899",
		oauthEndpoint: "/antigravity-auth-url",
		supportsQuotaOnlyMode: true,
		usesBrowserAuth: false,
		usesCLIQuota: false,
		supportsManualAuth: true,
		usesAPIKeyAuth: false,
		isQuotaTrackingOnly: false,
		menuBarSymbol: "A",
		logoAssetName: "antigravity",
		iconName: "wand.and.stars",
	},
	[AIProvider.VERTEX]: {
		id: AIProvider.VERTEX,
		displayName: "Vertex AI",
		color: "#EA4335",
		oauthEndpoint: null,
		supportsQuotaOnlyMode: false,
		usesBrowserAuth: false,
		usesCLIQuota: false,
		supportsManualAuth: true,
		usesAPIKeyAuth: false,
		isQuotaTrackingOnly: false,
		menuBarSymbol: "V",
		logoAssetName: "vertex",
		iconName: "cube",
	},
	[AIProvider.KIRO]: {
		id: AIProvider.KIRO,
		displayName: "Kiro (CodeWhisperer)",
		color: "#9046FF",
		oauthEndpoint: null,
		supportsQuotaOnlyMode: false,
		usesBrowserAuth: false,
		usesCLIQuota: false,
		supportsManualAuth: true,
		usesAPIKeyAuth: false,
		isQuotaTrackingOnly: false,
		menuBarSymbol: "K",
		logoAssetName: "kiro",
		iconName: "cloud.fill",
	},
	[AIProvider.COPILOT]: {
		id: AIProvider.COPILOT,
		displayName: "GitHub Copilot",
		color: "#238636",
		oauthEndpoint: null,
		supportsQuotaOnlyMode: true,
		usesBrowserAuth: false,
		usesCLIQuota: false,
		supportsManualAuth: true,
		usesAPIKeyAuth: false,
		isQuotaTrackingOnly: false,
		menuBarSymbol: "CP",
		logoAssetName: "copilot",
		iconName: "chevron.left.forwardslash.chevron.right",
	},
	[AIProvider.CURSOR]: {
		id: AIProvider.CURSOR,
		displayName: "Cursor",
		color: "#00D4AA",
		oauthEndpoint: null,
		supportsQuotaOnlyMode: true,
		usesBrowserAuth: true,
		usesCLIQuota: false,
		supportsManualAuth: false,
		usesAPIKeyAuth: false,
		isQuotaTrackingOnly: true,
		menuBarSymbol: "CR",
		logoAssetName: "cursor",
		iconName: "cursorarrow.rays",
	},
	[AIProvider.TRAE]: {
		id: AIProvider.TRAE,
		displayName: "Trae",
		color: "#00B4D8",
		oauthEndpoint: null,
		supportsQuotaOnlyMode: true,
		usesBrowserAuth: true,
		usesCLIQuota: false,
		supportsManualAuth: false,
		usesAPIKeyAuth: false,
		isQuotaTrackingOnly: true,
		menuBarSymbol: "TR",
		logoAssetName: "trae",
		iconName: "cursorarrow.rays",
	},
	[AIProvider.GLM]: {
		id: AIProvider.GLM,
		displayName: "GLM",
		color: "#3B82F6",
		oauthEndpoint: null,
		supportsQuotaOnlyMode: true,
		usesBrowserAuth: false,
		usesCLIQuota: false,
		supportsManualAuth: false, // Only via Custom Providers
		usesAPIKeyAuth: true,
		isQuotaTrackingOnly: false,
		menuBarSymbol: "G",
		logoAssetName: "glm",
		iconName: "brain",
	},
};

export function getProviderMetadata(provider: AIProvider): ProviderMetadata {
	return PROVIDER_METADATA[provider];
}

export function getQuotaOnlyProviders(): AIProvider[] {
	return Object.values(AIProvider).filter(
		(p) => PROVIDER_METADATA[p].supportsQuotaOnlyMode,
	);
}

export function getManualAuthProviders(): AIProvider[] {
	return Object.values(AIProvider).filter(
		(p) => PROVIDER_METADATA[p].supportsManualAuth,
	);
}

export function getRoutableProviders(): AIProvider[] {
	return Object.values(AIProvider).filter(
		(p) => !PROVIDER_METADATA[p].isQuotaTrackingOnly,
	);
}

export function parseProvider(providerString: string): AIProvider | null {
	if (providerString === "copilot") {
		return AIProvider.COPILOT;
	}
	const found = Object.values(AIProvider).find((p) => p === providerString);
	return found ?? null;
}
