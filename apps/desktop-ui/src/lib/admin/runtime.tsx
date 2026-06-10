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

export type NativeOpenTextFileRequest = {
  title: string;
  allowedExtensions?: string[];
};

export type NativeCredentialRequest = {
  targetName: string;
  value?: string;
};

type DesktopBridge = {
  request: <T>(request: DesktopBridgeRequest) => Promise<T>;
  runtimeStatus?: () => Promise<RuntimeStatus>;
  runtimeStart?: () => Promise<RuntimeStatus>;
  runtimeStop?: () => Promise<RuntimeStatus>;
  runtimeRestart?: () => Promise<RuntimeStatus>;
  confirm?: (request: NativeConfirmRequest) => Promise<boolean>;
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
  confirm: (request: NativeConfirmRequest) => Promise<boolean>;
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
      confirm,
      openExternal,
      openTextFile,
      credentialRead,
      credentialWrite,
      credentialDelete,
    }),
    [
      bootstrap,
      confirm,
      credentialDelete,
      credentialRead,
      credentialWrite,
      openExternal,
      openTextFile,
      request,
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
