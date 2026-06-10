import type {
  NativeCredential,
  RequestKind,
  RuntimeStatus,
} from '@quotio/desktop-contract/generated';
import {
  createContext,
  type ReactNode,
  useCallback,
  useContext,
  useMemo,
} from 'react';
import type { AdminBootstrap } from '@/lib/admin/bootstrap';

type DesktopBridgeRequest = {
  id: string;
  kind?: Extract<RequestKind, 'management.request'>;
  path: string;
  init?: {
    method?: string;
    body?: string;
  };
};

export type NativeConfirmRequest = {
  title: string;
  message: string;
  confirmLabel: string;
  cancelLabel: string;
  destructive?: boolean;
};

export type NativeNotifyRequest = {
  title: string;
  message: string;
  tone: 'success' | 'error';
};

export type NativeOpenTextFileRequest = {
  title: string;
  allowedExtensions?: string[];
};

export type NativeCredentialRequest = {
  targetName: string;
  value?: string;
};

export type NativePreferences = {
  operatingMode: 'local' | 'remote';
  remoteConfigured: boolean;
  language: 'en' | 'vi' | 'zh-Hans';
  appearance: 'system' | 'light' | 'dark';
  launchAtLogin: boolean;
  launchAtLoginCanOpenSystemSettings?: boolean;
  proxyPort: number;
  proxyEndpoint: string;
  proxyRunning: boolean;
  proxyServerKind: string;
  proxyServerVersion: string | null;
  proxyInstallStatus: string;
  proxyActiveBinaryPath: string;
  proxyConfigPath: string;
  allowNetworkAccess: boolean;
  autoStartTunnel: boolean;
  autoRestartTunnel: boolean;
  tunnelInstalled: boolean;
  authDir: string;
  defaultAuthDir: string;
  notificationsEnabled: boolean;
  notifyOnQuotaLow: boolean;
  notifyOnCooling: boolean;
  notifyOnProxyCrash: boolean;
  quotaAlertThreshold: 10 | 20 | 30 | 50;
  quotaDisplayMode: 'used' | 'remaining';
  quotaDisplayStyle: 'card' | 'lowestBar' | 'ring';
  resetTimeDisplayMode: 'relative' | 'absolute';
  refreshCadence: 'manual' | '1min' | '2min' | '5min' | '10min' | '15min';
  showInDock: boolean;
  showMenuBarIcon: boolean;
  showQuotaInMenuBar: boolean;
  menuBarMaxItems: number;
  menuBarColorMode: 'colored' | 'monochrome';
  hideSensitiveInfo: boolean;
  totalUsageMode: 'sessionOnly' | 'combined';
  modelAggregationMode: 'lowest' | 'average';
  updatesSupported: boolean;
  autoCheckUpdates: boolean;
  updateChannel: 'stable' | 'beta';
  updateChannelLocked: boolean;
  canCheckForUpdates: boolean;
  isCheckingForUpdates: boolean;
  lastUpdateCheckAt: string | null;
};

export type NativePreferencesPatch = Partial<
  Pick<
    NativePreferences,
    | 'appearance'
    | 'allowNetworkAccess'
    | 'authDir'
    | 'autoRestartTunnel'
    | 'autoStartTunnel'
    | 'hideSensitiveInfo'
    | 'language'
    | 'launchAtLogin'
    | 'menuBarColorMode'
    | 'menuBarMaxItems'
    | 'modelAggregationMode'
    | 'notificationsEnabled'
    | 'notifyOnCooling'
    | 'notifyOnProxyCrash'
    | 'notifyOnQuotaLow'
    | 'operatingMode'
    | 'proxyPort'
    | 'quotaAlertThreshold'
    | 'quotaDisplayMode'
    | 'quotaDisplayStyle'
    | 'refreshCadence'
    | 'resetTimeDisplayMode'
    | 'showInDock'
    | 'showMenuBarIcon'
    | 'showQuotaInMenuBar'
    | 'totalUsageMode'
    | 'autoCheckUpdates'
    | 'updateChannel'
  >
>;

type DesktopBridge = {
  request: <T>(request: DesktopBridgeRequest) => Promise<T>;
  runtimeStatus?: () => Promise<RuntimeStatus>;
  runtimeStart?: () => Promise<RuntimeStatus>;
  runtimeStop?: () => Promise<RuntimeStatus>;
  runtimeRestart?: () => Promise<RuntimeStatus>;
  confirm?: (request: NativeConfirmRequest) => Promise<boolean>;
  notify?: (request: NativeNotifyRequest) => Promise<boolean>;
  openExternal?: (url: string) => Promise<boolean>;
  openTextFile?: (request: NativeOpenTextFileRequest) => Promise<string | null>;
  credentialRead?: (
    request: Pick<NativeCredentialRequest, 'targetName'>,
  ) => Promise<NativeCredential>;
  credentialWrite?: (
    request: Required<NativeCredentialRequest>,
  ) => Promise<boolean>;
  credentialDelete?: (
    request: Pick<NativeCredentialRequest, 'targetName'>,
  ) => Promise<boolean>;
  preferencesRead?: () => Promise<NativePreferences>;
  preferencesWrite?: (request: {
    preferences: NativePreferencesPatch;
  }) => Promise<NativePreferences>;
  updatesCheck?: () => Promise<NativePreferences>;
};

declare global {
  interface Window {
    __QUOTIO_DESKTOP_BRIDGE__?: DesktopBridge;
  }
}

type AdminRuntimeValue = {
  bootstrap: AdminBootstrap;
  token: null;
  authStatus: 'authenticated';
  authError: null;
  isAuthenticated: true;
  verifyToken: () => Promise<boolean>;
  clearToken: () => void;
  request: <T>(path: string, init?: RequestInit) => Promise<T>;
  runtimeStatus: () => Promise<RuntimeStatus>;
  runtimeStart: () => Promise<RuntimeStatus>;
  runtimeStop: () => Promise<RuntimeStatus>;
  runtimeRestart: () => Promise<RuntimeStatus>;
  confirm: (request: NativeConfirmRequest) => Promise<boolean>;
  notify: (request: NativeNotifyRequest) => Promise<boolean>;
  openExternal: (url: string) => Promise<boolean>;
  openTextFile: (request: NativeOpenTextFileRequest) => Promise<string | null>;
  credentialRead: (
    request: Pick<NativeCredentialRequest, 'targetName'>,
  ) => Promise<NativeCredential>;
  credentialWrite: (
    request: Required<NativeCredentialRequest>,
  ) => Promise<boolean>;
  credentialDelete: (
    request: Pick<NativeCredentialRequest, 'targetName'>,
  ) => Promise<boolean>;
  preferencesRead: () => Promise<NativePreferences>;
  preferencesWrite: (
    preferences: NativePreferencesPatch,
  ) => Promise<NativePreferences>;
  updatesCheck: () => Promise<NativePreferences>;
};

const AdminRuntimeContext = createContext<AdminRuntimeValue | null>(null);

export function AdminRuntimeProvider({
  bootstrap,
  children,
}: {
  bootstrap: AdminBootstrap;
  children: ReactNode;
}) {
  const request = useCallback(async <T,>(path: string, init?: RequestInit) => {
    const bridge = window.__QUOTIO_DESKTOP_BRIDGE__;

    if (!bridge) {
      throw new Error('Desktop host bridge is unavailable');
    }

    return bridge.request<T>({
      id: crypto.randomUUID(),
      kind: 'management.request',
      path,
      init: {
        method: init?.method,
        body: typeof init?.body === 'string' ? init.body : undefined,
      },
    });
  }, []);

  const confirm = useCallback(async (request: NativeConfirmRequest) => {
    const bridge = window.__QUOTIO_DESKTOP_BRIDGE__;

    if (bridge?.confirm) {
      return bridge.confirm(request);
    }

    return window.confirm(request.message);
  }, []);

  const notify = useCallback(async (request: NativeNotifyRequest) => {
    const bridge = window.__QUOTIO_DESKTOP_BRIDGE__;

    if (bridge?.notify) {
      return bridge.notify(request);
    }

    return false;
  }, []);

  const openExternal = useCallback(async (url: string) => {
    const bridge = window.__QUOTIO_DESKTOP_BRIDGE__;

    if (bridge?.openExternal) {
      return bridge.openExternal(url);
    }

    return window.open(url, '_blank', 'noopener,noreferrer') !== null;
  }, []);

  const openTextFile = useCallback(
    async (request: NativeOpenTextFileRequest) => {
      const bridge = window.__QUOTIO_DESKTOP_BRIDGE__;

      if (bridge?.openTextFile) {
        return bridge.openTextFile(request);
      }

      const input = document.createElement('input');
      input.type = 'file';
      input.accept = (request.allowedExtensions ?? [])
        .map((extension) => `.${extension}`)
        .join(',');

      return new Promise<string | null>((resolve, reject) => {
        input.onchange = () => {
          const file = input.files?.[0];
          if (!file) {
            resolve(null);
            return;
          }

          file.text().then(resolve, reject);
        };
        input.oncancel = () => resolve(null);
        input.click();
      });
    },
    [],
  );

  const runtimeStatus = useCallback(async () => {
    const bridge = window.__QUOTIO_DESKTOP_BRIDGE__;

    if (!bridge?.runtimeStatus) {
      throw new Error('Desktop runtime bridge is unavailable');
    }

    return bridge.runtimeStatus();
  }, []);

  const runtimeStart = useCallback(async () => {
    const bridge = window.__QUOTIO_DESKTOP_BRIDGE__;

    if (!bridge?.runtimeStart) {
      throw new Error('Desktop runtime bridge is unavailable');
    }

    return bridge.runtimeStart();
  }, []);

  const runtimeStop = useCallback(async () => {
    const bridge = window.__QUOTIO_DESKTOP_BRIDGE__;

    if (!bridge?.runtimeStop) {
      throw new Error('Desktop runtime bridge is unavailable');
    }

    return bridge.runtimeStop();
  }, []);

  const runtimeRestart = useCallback(async () => {
    const bridge = window.__QUOTIO_DESKTOP_BRIDGE__;

    if (!bridge?.runtimeRestart) {
      throw new Error('Desktop runtime bridge is unavailable');
    }

    return bridge.runtimeRestart();
  }, []);

  const credentialRead = useCallback(
    async (request: Pick<NativeCredentialRequest, 'targetName'>) => {
      const bridge = window.__QUOTIO_DESKTOP_BRIDGE__;

      if (!bridge?.credentialRead) {
        throw new Error('Desktop credential bridge is unavailable');
      }

      return bridge.credentialRead(request);
    },
    [],
  );

  const credentialWrite = useCallback(
    async (request: Required<NativeCredentialRequest>) => {
      const bridge = window.__QUOTIO_DESKTOP_BRIDGE__;

      if (!bridge?.credentialWrite) {
        throw new Error('Desktop credential bridge is unavailable');
      }

      return bridge.credentialWrite(request);
    },
    [],
  );

  const credentialDelete = useCallback(
    async (request: Pick<NativeCredentialRequest, 'targetName'>) => {
      const bridge = window.__QUOTIO_DESKTOP_BRIDGE__;

      if (!bridge?.credentialDelete) {
        throw new Error('Desktop credential bridge is unavailable');
      }

      return bridge.credentialDelete(request);
    },
    [],
  );

  const preferencesRead = useCallback(async () => {
    const bridge = window.__QUOTIO_DESKTOP_BRIDGE__;

    if (!bridge?.preferencesRead) {
      throw new Error('Desktop preferences bridge is unavailable');
    }

    return bridge.preferencesRead();
  }, []);

  const preferencesWrite = useCallback(
    async (preferences: NativePreferencesPatch) => {
      const bridge = window.__QUOTIO_DESKTOP_BRIDGE__;

      if (!bridge?.preferencesWrite) {
        throw new Error('Desktop preferences bridge is unavailable');
      }

      return bridge.preferencesWrite({ preferences });
    },
    [],
  );

  const updatesCheck = useCallback(async () => {
    const bridge = window.__QUOTIO_DESKTOP_BRIDGE__;

    if (!bridge?.updatesCheck) {
      throw new Error('Desktop updates bridge is unavailable');
    }

    return bridge.updatesCheck();
  }, []);

  const value = useMemo<AdminRuntimeValue>(
    () => ({
      bootstrap,
      token: null,
      authStatus: 'authenticated',
      authError: null,
      isAuthenticated: true,
      verifyToken: async () => true,
      clearToken: () => {},
      request,
      runtimeStatus,
      runtimeStart,
      runtimeStop,
      runtimeRestart,
      confirm,
      notify,
      openExternal,
      openTextFile,
      credentialRead,
      credentialWrite,
      credentialDelete,
      preferencesRead,
      preferencesWrite,
      updatesCheck,
    }),
    [
      bootstrap,
      confirm,
      credentialDelete,
      credentialRead,
      credentialWrite,
      notify,
      openExternal,
      openTextFile,
      preferencesRead,
      preferencesWrite,
      request,
      runtimeRestart,
      runtimeStart,
      runtimeStatus,
      runtimeStop,
      updatesCheck,
    ],
  );

  return (
    <AdminRuntimeContext.Provider value={value}>
      {children}
    </AdminRuntimeContext.Provider>
  );
}

export function useAdminRuntime() {
  const context = useContext(AdminRuntimeContext);

  if (!context) {
    throw new Error('useAdminRuntime must be used within AdminRuntimeProvider');
  }

  return context;
}

export function useIsNativeDesktopRuntime() {
  const { bootstrap } = useAdminRuntime();
  return bootstrap.platform === 'macos' || bootstrap.platform === 'windows';
}
