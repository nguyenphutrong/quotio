// ============================================
// Quotio - Preload Script (Context Bridge)
// Security: Exposes only validated APIs to renderer
// ============================================

import { contextBridge, ipcRenderer, IpcRendererEvent } from 'electron';
import { IPC_CHANNELS } from '../shared/constants';
import { isValidIPCChannel } from '../shared/utils/security';

// Type definitions for exposed APIs
interface ElectronAPI {
  // Proxy Management
  proxy: {
    start: () => Promise<{ success: boolean; error?: string }>;
    stop: () => Promise<{ success: boolean; error?: string }>;
    getStatus: () => Promise<{
      isRunning: boolean;
      port: number;
      uptime?: number;
      requestCount: number;
      errorCount: number;
    }>;
    onStatusChanged: (callback: (status: unknown) => void) => () => void;
  };

  // Quota Management
  quota: {
    getAll: () => Promise<unknown[]>;
    refresh: (provider?: string) => Promise<{ success: boolean; error?: string }>;
    onUpdated: (callback: (quota: unknown) => void) => () => void;
  };

  // Settings
  settings: {
    get: () => Promise<unknown>;
    update: (settings: Record<string, unknown>) => Promise<{ success: boolean; error?: string }>;
  };

  // Agent Management
  agent: {
    getAll: () => Promise<unknown[]>;
    configure: (config: Record<string, unknown>) => Promise<{ success: boolean; error?: string }>;
  };

  // Logs
  logs: {
    get: () => Promise<unknown[]>;
    clear: () => Promise<{ success: boolean }>;
  };

  // Stats
  stats: {
    get: () => Promise<unknown>;
  };

  // Window
  window: {
    openMain: () => Promise<{ success: boolean }>;
    minimize: () => void;
    close: () => void;
  };

  // Platform info
  platform: {
    isMac: boolean;
    isWindows: boolean;
    isLinux: boolean;
  };
}

// Helper to create safe IPC invokers
function createInvoker<T>(channel: string): () => Promise<T> {
  return async (): Promise<T> => {
    if (!isValidIPCChannel(channel)) {
      throw new Error(`Invalid IPC channel: ${channel}`);
    }
    return ipcRenderer.invoke(channel) as Promise<T>;
  };
}

function createInvokerWithArg<T, A>(channel: string): (arg: A) => Promise<T> {
  return async (arg: A): Promise<T> => {
    if (!isValidIPCChannel(channel)) {
      throw new Error(`Invalid IPC channel: ${channel}`);
    }
    return ipcRenderer.invoke(channel, arg) as Promise<T>;
  };
}

// Helper to create safe event listeners
function createListener<T>(channel: string): (callback: (data: T) => void) => () => void {
  return (callback: (data: T) => void): () => void => {
    if (!isValidIPCChannel(channel)) {
      throw new Error(`Invalid IPC channel: ${channel}`);
    }

    const handler = (_event: IpcRendererEvent, data: T): void => {
      callback(data);
    };

    ipcRenderer.on(channel, handler);

    // Return unsubscribe function
    return () => {
      ipcRenderer.removeListener(channel, handler);
    };
  };
}

// Expose the API to the renderer process
const electronAPI: ElectronAPI = {
  proxy: {
    start: createInvoker(IPC_CHANNELS.PROXY_START),
    stop: createInvoker(IPC_CHANNELS.PROXY_STOP),
    getStatus: createInvoker(IPC_CHANNELS.PROXY_STATUS),
    onStatusChanged: createListener(IPC_CHANNELS.PROXY_STATUS_CHANGED),
  },

  quota: {
    getAll: createInvoker(IPC_CHANNELS.QUOTA_GET_ALL),
    refresh: createInvokerWithArg(IPC_CHANNELS.QUOTA_REFRESH),
    onUpdated: createListener(IPC_CHANNELS.QUOTA_UPDATED),
  },

  settings: {
    get: createInvoker(IPC_CHANNELS.SETTINGS_GET),
    update: createInvokerWithArg(IPC_CHANNELS.SETTINGS_UPDATE),
  },

  agent: {
    getAll: createInvoker(IPC_CHANNELS.AGENT_GET_ALL),
    configure: createInvokerWithArg(IPC_CHANNELS.AGENT_CONFIGURE),
  },

  logs: {
    get: createInvoker(IPC_CHANNELS.LOG_GET),
    clear: createInvoker(IPC_CHANNELS.LOG_CLEAR),
  },

  stats: {
    get: createInvoker(IPC_CHANNELS.STATS_GET),
  },

  window: {
    openMain: createInvoker(IPC_CHANNELS.WINDOW_OPEN_MAIN),
    minimize: () => {
      ipcRenderer.send('window:minimize');
    },
    close: () => {
      ipcRenderer.send('window:close');
    },
  },

  platform: {
    isMac: process.platform === 'darwin',
    isWindows: process.platform === 'win32',
    isLinux: process.platform === 'linux',
  },
};

// Expose to renderer via context bridge
contextBridge.exposeInMainWorld('electron', electronAPI);

// Type declaration for renderer process
declare global {
  interface Window {
    electron: ElectronAPI;
  }
}
