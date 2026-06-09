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

export const DEFAULT_FEATURE_FLAGS: AdminFeatureFlags = {
  overview: true,
  providers: true,
  quota: true,
  usage: false,
  virtualModels: false,
  models: false,
  agents: false,
  apiKeys: false,
  logs: false,
  settings: false,
  about: false,
};

export type AdminBootstrap = {
  uiEnabled: boolean;
  basePath: string;
  bridgeVersion: number;
  serverListen: string;
  platform: 'macos' | 'windows' | 'unknown';
  locale: string;
  appearance: 'light' | 'dark' | 'system';
  features: AdminFeatureFlags;
};

type DesktopBootstrapPayload = Omit<Partial<AdminBootstrap>, 'features'> & {
  features?: Partial<AdminFeatureFlags>;
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

export function getDesktopBootstrap(): AdminBootstrap {
  const payload = window.__QUOTIO_DESKTOP_BOOTSTRAP__;

  if (payload?.uiEnabled === false) {
    throw new AdminBootstrapError('Desktop UI is disabled by host bootstrap');
  }

  return {
    uiEnabled: true,
    basePath: normalizeBasePath(payload?.basePath),
    bridgeVersion: payload?.bridgeVersion ?? 1,
    serverListen: payload?.serverListen?.trim() ?? 'localhost:8386',
    platform: payload?.platform ?? 'unknown',
    locale: payload?.locale ?? navigator.language,
    appearance: payload?.appearance ?? 'system',
    features: normalizeFeatureFlags(payload?.features),
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
