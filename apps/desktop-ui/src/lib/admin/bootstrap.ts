import { AdminBootstrapError } from '@/lib/admin/errors';

declare global {
  interface Window {
    __QUOTIO_DESKTOP_BOOTSTRAP__?: Partial<AdminBootstrap>;
  }
}

export type AdminBootstrap = {
  uiEnabled: boolean;
  basePath: string;
  bridgeVersion: number;
  serverListen: string;
  platform: 'macos' | 'windows' | 'unknown';
  locale: string;
  appearance: 'light' | 'dark' | 'system';
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
  };
}
