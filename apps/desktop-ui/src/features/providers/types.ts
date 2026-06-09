export type ProviderValidation = {
  valid: boolean;
  auth_type: string;
  supported_models?: string[];
  account_identity?: string;
  expires_at?: string;
  duplicate_provider_ids?: string[];
  warnings?: string[];
  checked_at?: string;
  error?: string;
};

export type ProviderResponse = {
  id: string;
  type?: string; // "oauth" | "api_key"
  provider: string;
  label: string;
  disabled?: boolean;
  secret: string;
  project_id?: string;
  priority?: number;
  prefix?: string;
  base_url?: string;
  proxy_url?: string;
  headers?: Record<string, string>;
  excluded_models?: string[];
  validation: ProviderValidation;
};

export type ProviderPayload = {
  id?: string;
  type?: string;
  provider: string;
  label: string;
  disabled: boolean;
  secret: string;
  project_id?: string;
  priority?: number;
  prefix?: string;
  base_url?: string;
  proxy_url?: string;
  headers?: Record<string, string>;
  excluded_models?: string[];
  auth_type?: string;
};

export type ProviderTestSummary = {
  provider: string;
  checked_at: string;
  supported_models?: string[];
  providers?: Array<{
    refreshed?: boolean;
    last_error?: string;
  }>;
};

export type ProviderActionResult = {
  provider?: ProviderResponse;
  revoked?: boolean;
};

export type ProviderOAuthSessionStatus =
  | 'idle'
  | 'starting'
  | 'awaiting_callback'
  | 'awaiting_device_confirmation'
  | 'completed'
  | 'failed'
  | 'expired';

export type ProviderOAuthSession = {
  session_id: string;
  provider: string;
  status: ProviderOAuthSessionStatus;
  auth_url?: string;
  verification_uri?: string;
  user_code?: string;
  expires_at?: string;
  interval_seconds?: number;
  error?: string;
  credential?: ProviderResponse;
};

export type ProviderOnboardingMode =
  | 'oauth'
  | 'device_code'
  | 'api_key'
  | 'manual'
  | 'custom';

export function normalizeProviderId(value: string) {
  const normalized = value.trim().toLowerCase();
  switch (normalized) {
    case 'glm':
    case 'zai':
    case 'z.ai':
      return 'z-ai';
    case 'vertex_anthropic':
    case 'vertex (anthropic)':
      return 'vertex-anthropic';
    case 'ag':
      return 'antigravity';
    default:
      return normalized;
  }
}

// OAuth Providers (require browser callback)
export const oauthProviders = [
  'anthropic', // Claude Code
  'antigravity',
  'codex', // ChatGPT Codex
  'gemini', // Google Gemini
  'iflow',
  'kiro',
] as const;

// Device-code providers
export const deviceCodeProviders = [
  'github-copilot', // GitHub Copilot
  'qwen',
] as const;

// API Key Providers (compatible with OpenAI/Anthropic Messages API)
export const apiKeyProviders = [
  'openai',
  'opencode',
  'opencode-go',
  'z-ai',
  'groq',
  'azure-openai',
  'bedrock',
  'ollama',
  'openrouter',
  'cerebras',
  'fireworks',
  'vercel-ai-gateway',
  'together',
  'xai',
  'fastrouter',
  'cortecs',
  'kimi', // Moonshot AI
  'minimax', // MiniMax
] as const;

// Providers that need explicit runtime config instead of OAuth/device-code.
export const manualProviders = ['vertex', 'vertex-anthropic'] as const;

export type OAuthProvider = (typeof oauthProviders)[number];
export type DeviceCodeProvider = (typeof deviceCodeProviders)[number];
export type APIKeyProvider = (typeof apiKeyProviders)[number];
export type ManualProvider = (typeof manualProviders)[number];
export type ProviderOption =
  | OAuthProvider
  | DeviceCodeProvider
  | APIKeyProvider
  | ManualProvider;

export const providerOptions = [
  ...oauthProviders,
  ...deviceCodeProviders,
  ...apiKeyProviders,
  ...manualProviders,
] as const;

export function normalizePayload(input: ProviderPayload): ProviderPayload {
  return {
    ...input,
    provider: normalizeProviderId(input.provider),
    label: input.label.trim(),
    secret: input.secret.trim(),
    project_id: input.project_id?.trim() || undefined,
    prefix: input.prefix?.trim() || undefined,
    base_url: input.base_url?.trim() || undefined,
    proxy_url: input.proxy_url?.trim() || undefined,
    headers:
      input.headers && Object.keys(input.headers).length > 0
        ? input.headers
        : undefined,
    excluded_models:
      input.excluded_models?.map((value) => value.trim()).filter(Boolean) ??
      undefined,
  };
}

// Provider catalog with metadata
export const providerCatalog: Record<
  string,
  {
    name: string;
    type: 'oauth' | 'api_key';
    onboarding: Exclude<ProviderOnboardingMode, 'custom'>;
    icon?: string;
    baseURL?: string;
    description?: string;
  }
> = {
  // OAuth Providers
  anthropic: {
    name: 'Claude Code',
    type: 'oauth',
    onboarding: 'oauth',
    icon: '🤖',
    description: 'Anthropic Claude via OAuth',
  },
  codex: {
    name: 'ChatGPT Codex',
    type: 'oauth',
    onboarding: 'oauth',
    icon: '💬',
    description: 'OpenAI ChatGPT/Codex via OAuth',
  },
  'github-copilot': {
    name: 'GitHub Copilot',
    type: 'oauth',
    onboarding: 'device_code',
    icon: '👨‍💻',
    description: 'GitHub Copilot via OAuth',
  },
  gemini: {
    name: 'Google Gemini',
    type: 'oauth',
    onboarding: 'oauth',
    icon: '✨',
    description: 'Google Gemini via OAuth',
  },
  iflow: {
    name: 'iFlow',
    type: 'oauth',
    onboarding: 'oauth',
    icon: '🌊',
    baseURL: 'https://apis.iflow.cn/v1',
    description: 'iFlow via browser OAuth',
  },
  qwen: {
    name: 'Qwen',
    type: 'oauth',
    onboarding: 'device_code',
    icon: '🧠',
    baseURL: 'https://portal.qwen.ai/v1',
    description: 'Qwen via device code',
  },
  kiro: {
    name: 'Kiro',
    type: 'oauth',
    onboarding: 'oauth',
    icon: '🛠️',
    description: 'Kiro via browser OAuth',
  },

  // API Key Providers - OpenAI Compatible
  antigravity: {
    name: 'Antigravity',
    type: 'oauth',
    onboarding: 'oauth',
    icon: '🚀',
    baseURL: 'https://cloudcode-pa.googleapis.com',
    description:
      'Connect Antigravity with OAuth. Project ID is fetched automatically after login.',
  },
  openai: {
    name: 'OpenAI API',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '💬',
    baseURL: 'https://api.openai.com',
    description: 'OpenAI API key',
  },
  opencode: {
    name: 'OpenCode Zen',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '🧿',
    baseURL: 'https://opencode.ai/zen',
    description: 'Protocol-per-model gateway for curated coding models',
  },
  'opencode-go': {
    name: 'OpenCode Go',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '🧿',
    baseURL: 'https://opencode.ai/zen/go',
    description:
      'Low-cost OpenCode subscription with protocol-per-model routing',
  },
  'z-ai': {
    name: 'Z.AI / GLM Coding Plan',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '⚪',
    baseURL: 'https://api.z.ai/api/coding/paas/v4',
    description: 'Dual-protocol Z.AI / GLM Coding Plan',
  },
  kimi: {
    name: 'Kimi',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '🌙',
    baseURL: 'https://api.moonshot.cn',
    description: 'Moonshot AI Kimi',
  },
  minimax: {
    name: 'MiniMax',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '🧠',
    baseURL: 'https://api.minimax.chat',
    description: 'MiniMax Coding',
  },
  fireworks: {
    name: 'Fireworks',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '🔥',
    baseURL: 'https://api.fireworks.ai/inference/v1',
    description: 'Fireworks API',
  },
  groq: {
    name: 'Groq',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '⚡',
    baseURL: 'https://api.groq.com/openai',
    description: 'Groq API',
  },
  'azure-openai': {
    name: 'Azure OpenAI',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '☁️',
    description: 'Microsoft Azure OpenAI',
  },
  bedrock: {
    name: 'AWS Bedrock',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '🏔️',
    description: 'Amazon Bedrock',
  },
  ollama: {
    name: 'Ollama',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '🦙',
    baseURL: 'http://127.0.0.1:11434',
    description: 'Local Ollama server',
  },
  openrouter: {
    name: 'OpenRouter',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '🧭',
    baseURL: 'https://openrouter.ai/api/v1',
    description: 'OpenRouter gateway',
  },
  cerebras: {
    name: 'Cerebras',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '🧪',
    baseURL: 'https://api.cerebras.ai/v1',
    description: 'Cerebras API',
  },
  'vercel-ai-gateway': {
    name: 'Vercel AI Gateway',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '▲',
    baseURL: 'https://ai-gateway.vercel.sh/v3/ai',
    description: 'Vercel AI Gateway',
  },
  together: {
    name: 'Together AI',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '🤝',
    baseURL: 'https://api.together.xyz/v1',
    description: 'Together AI API',
  },
  xai: {
    name: 'xAI',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '✕',
    baseURL: 'https://api.x.ai/v1',
    description: 'xAI API',
  },
  fastrouter: {
    name: 'FastRouter',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '🚀',
    description: 'FastRouter gateway',
  },
  cortecs: {
    name: 'Cortecs',
    type: 'api_key',
    onboarding: 'api_key',
    icon: '🧩',
    description: 'Cortecs service',
  },
  vertex: {
    name: 'Vertex',
    type: 'api_key',
    onboarding: 'manual',
    icon: '🔷',
    description: 'Explicit runtime config for Gemini-native Vertex models',
  },
  'vertex-anthropic': {
    name: 'Vertex (Anthropic)',
    type: 'api_key',
    onboarding: 'manual',
    icon: '🔶',
    description: 'Explicit runtime config for Anthropic models on Vertex',
  },
};

export function getProviderDisplayName(providerId: string, fallback?: string) {
  const normalized = normalizeProviderId(providerId);
  return providerCatalog[normalized]?.name || fallback || normalized;
}

export function getProviderDescription(providerId: string, fallback?: string) {
  const normalized = normalizeProviderId(providerId);
  return providerCatalog[normalized]?.description || fallback || normalized;
}
