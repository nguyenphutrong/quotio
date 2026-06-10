import { AdminBootstrapError } from '@/lib/admin/errors';

declare global {
  interface Window {
    __QUOTIO_DESKTOP_BOOTSTRAP__?: DesktopBootstrapPayload;
  }
}

export const FEATURE_ROUTE_MAP = {
  overview: '/overview',
  providers: '/providers',
  quota: '/quota',
  usage: '/usage',
  virtualModels: '/virtual-models',
  models: '/models',
  agents: '/agents',
  apiKeys: '/api-keys',
  logs: '/logs',
  settings: '/settings',
  about: '/about',
} as const;

export type ScreenFeatureKey = keyof typeof FEATURE_ROUTE_MAP;
export type AdminFeatureFlags = Record<ScreenFeatureKey, boolean>;

export type OperatingMode = 'local' | 'remote' | 'quota-only';
export type HostAppearance = 'light' | 'dark' | 'system';
export type HostAuthStatus = 'authenticated' | 'disconnected';

export type HostCapabilities = {
  supportsLocalProxy: boolean;
  supportsProxyControl: boolean;
  supportsPortConfig: boolean;
  supportsCliOAuth: boolean;
  supportsAgentConfig: boolean;
  supportsRemoteConnections: boolean;
  supportsCredentialStorage: boolean;
  supportsManagementBridge: boolean;
  supportsNativeOnboarding: boolean;
  supportsNativePreferences: boolean;
  supportsAppearanceSync: boolean;
  supportsRequestLogSettings: boolean;
  supportsModelSettings: boolean;
  supportsApiKeyManagement: boolean;
  supportsVirtualModelManagement: boolean;
  supportsUpdates: boolean;
};

export const DEFAULT_FEATURE_FLAGS: AdminFeatureFlags = {
  overview: true,
  providers: true,
  quota: true,
  usage: false,
  virtualModels: true,
  models: true,
  agents: false,
  apiKeys: true,
  logs: true,
  settings: true,
  about: true,
};

export const DEFAULT_HOST_CAPABILITIES: HostCapabilities = {
  supportsLocalProxy: false,
  supportsProxyControl: false,
  supportsPortConfig: false,
  supportsCliOAuth: false,
  supportsAgentConfig: false,
  supportsRemoteConnections: false,
  supportsCredentialStorage: false,
  supportsManagementBridge: false,
  supportsNativeOnboarding: false,
  supportsNativePreferences: false,
  supportsAppearanceSync: false,
  supportsRequestLogSettings: false,
  supportsModelSettings: false,
  supportsApiKeyManagement: false,
  supportsVirtualModelManagement: false,
  supportsUpdates: false,
};

export type AdminBootstrap = {
  uiEnabled: boolean;
  basePath: string;
  bridgeVersion: number;
  serverListen: string;
  platform: 'macos' | 'windows' | 'unknown';
  operatingMode: OperatingMode;
  authStatus: HostAuthStatus;
  locale: string;
  appearance: HostAppearance;
  features: AdminFeatureFlags;
  capabilities: HostCapabilities;
};

type DesktopBootstrapPayload = Omit<Partial<AdminBootstrap>, 'features'> & {
  features?: Partial<AdminFeatureFlags>;
  capabilities?: Partial<HostCapabilities>;
};

function normalizeBasePath(value?: string | null) {
  const trimmed = value?.trim();

  if (!trimmed) {
    return '/';
  }

  if (trimmed === '/') {
    return '/';
  }

  return trimmed.endsWith('/') ? trimmed.slice(0, -1) : trimmed;
}

function normalizeFeatureFlags(features?: Partial<AdminFeatureFlags>) {
  return {
    ...DEFAULT_FEATURE_FLAGS,
    ...Object.fromEntries(
      Object.entries(features ?? {}).filter(
        ([, value]) => typeof value === 'boolean',
      ),
    ),
  } as AdminFeatureFlags;
}

function normalizeOperatingMode(value?: string | null): OperatingMode {
  if (value === 'local' || value === 'remote' || value === 'quota-only') {
    return value;
  }
  return 'local';
}

function normalizeAppearance(value?: string | null): HostAppearance {
  if (value === 'light' || value === 'dark' || value === 'system') {
    return value;
  }
  return 'system';
}

function normalizeAuthStatus(
  value: string | null | undefined,
  capabilities: HostCapabilities,
): HostAuthStatus {
  if (value === 'authenticated' || value === 'disconnected') {
    return value;
  }
  return capabilities.supportsManagementBridge
    ? 'authenticated'
    : 'disconnected';
}

function normalizeCapabilities(capabilities?: Partial<HostCapabilities>) {
  return {
    ...DEFAULT_HOST_CAPABILITIES,
    ...Object.fromEntries(
      Object.entries(capabilities ?? {}).filter(
        ([, value]) => typeof value === 'boolean',
      ),
    ),
  } as HostCapabilities;
}

export function getDesktopBootstrap(): AdminBootstrap {
  const payload = window.__QUOTIO_DESKTOP_BOOTSTRAP__;
  const capabilities = normalizeCapabilities(payload?.capabilities);

  if (payload?.uiEnabled === false) {
    throw new AdminBootstrapError('Desktop UI is disabled by host bootstrap');
  }

  return {
    uiEnabled: true,
    basePath: normalizeBasePath(payload?.basePath),
    bridgeVersion: payload?.bridgeVersion ?? 1,
    serverListen: payload?.serverListen?.trim() ?? 'localhost:8386',
    platform: payload?.platform ?? 'unknown',
    operatingMode: normalizeOperatingMode(payload?.operatingMode),
    authStatus: normalizeAuthStatus(payload?.authStatus, capabilities),
    locale: payload?.locale ?? navigator.language,
    appearance: normalizeAppearance(payload?.appearance),
    features: normalizeFeatureFlags(payload?.features),
    capabilities,
  };
}

export function getFirstEnabledRoute(features: AdminFeatureFlags) {
  const feature = (
    Object.keys(DEFAULT_FEATURE_FLAGS) as ScreenFeatureKey[]
  ).find((key) => features[key]);

  return feature ? FEATURE_ROUTE_MAP[feature] : FEATURE_ROUTE_MAP.overview;
}

export function isBootstrapFeatureEnabled(feature: ScreenFeatureKey) {
  return getDesktopBootstrap().features[feature];
}
