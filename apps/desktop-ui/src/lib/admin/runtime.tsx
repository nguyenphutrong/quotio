import type {
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

type DesktopBridge = {
  request: <T>(request: DesktopBridgeRequest) => Promise<T>;
  runtimeStatus?: () => Promise<RuntimeStatus>;
  confirm?: (request: NativeConfirmRequest) => Promise<boolean>;
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
    }),
    [bootstrap, confirm, request],
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
