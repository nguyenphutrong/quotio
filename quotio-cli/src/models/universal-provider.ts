export interface UniversalProvider {
	id: string;
	name: string;
	baseURL: string;
	modelId: string;
	isBuiltIn: boolean;
	iconAssetName?: string;
	color: string;
	supportedAgents: string[];
	isEnabled: boolean;
	createdAt: string;
	updatedAt: string;
}

export interface ActiveProviderState {
	providerIdByAgent: Record<string, string>;
}

export const BUILT_IN_PROVIDERS: UniversalProvider[] = [
	{
		id: "00000000-0000-0000-0000-000000000001",
		name: "Anthropic",
		baseURL: "https://api.anthropic.com",
		modelId: "claude-sonnet-4-20250514",
		isBuiltIn: true,
		iconAssetName: "claude",
		color: "#D97706",
		supportedAgents: [],
		isEnabled: true,
		createdAt: new Date().toISOString(),
		updatedAt: new Date().toISOString(),
	},
	{
		id: "00000000-0000-0000-0000-000000000002",
		name: "OpenAI",
		baseURL: "https://api.openai.com/v1",
		modelId: "gpt-4o",
		isBuiltIn: true,
		iconAssetName: "codex",
		color: "#10B981",
		supportedAgents: [],
		isEnabled: true,
		createdAt: new Date().toISOString(),
		updatedAt: new Date().toISOString(),
	},
	{
		id: "00000000-0000-0000-0000-000000000003",
		name: "Google Gemini",
		baseURL: "https://generativelanguage.googleapis.com",
		modelId: "gemini-2.5-pro",
		isBuiltIn: true,
		iconAssetName: "gemini",
		color: "#4285F4",
		supportedAgents: [],
		isEnabled: true,
		createdAt: new Date().toISOString(),
		updatedAt: new Date().toISOString(),
	},
	{
		id: "00000000-0000-0000-0000-000000000004",
		name: "OpenRouter",
		baseURL: "https://openrouter.ai/api/v1",
		modelId: "",
		isBuiltIn: true,
		iconAssetName: undefined,
		color: "#6366F1",
		supportedAgents: [],
		isEnabled: true,
		createdAt: new Date().toISOString(),
		updatedAt: new Date().toISOString(),
	},
];

export function getProviderInitials(name: string): string {
	const words = name.split(" ");
	const first = words[0];
	const second = words[1];
	if (words.length >= 2 && first?.[0] && second?.[0]) {
		return (first[0] + second[0]).toUpperCase();
	}
	return name.slice(0, 2).toUpperCase();
}

export function supportsAgent(
	provider: UniversalProvider,
	agentId: string,
): boolean {
	return (
		provider.supportedAgents.length === 0 ||
		provider.supportedAgents.includes(agentId)
	);
}
