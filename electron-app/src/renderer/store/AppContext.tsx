import { createContext, useContext, useReducer, useEffect, type ReactNode } from 'react';
import type { ProxyStatus, QuotaInfo, CLIAgent, AppSettings, UsageStats } from '@shared/types';

// State Types
interface AppState {
  isInitialized: boolean;
  proxyStatus: ProxyStatus;
  quotas: QuotaInfo[];
  agents: CLIAgent[];
  settings: AppSettings;
  stats: UsageStats | null;
  isLoading: boolean;
  error: string | null;
}

// Action Types
type AppAction =
  | { type: 'SET_INITIALIZED'; payload: boolean }
  | { type: 'SET_PROXY_STATUS'; payload: ProxyStatus }
  | { type: 'SET_QUOTAS'; payload: QuotaInfo[] }
  | { type: 'UPDATE_QUOTA'; payload: QuotaInfo }
  | { type: 'SET_AGENTS'; payload: CLIAgent[] }
  | { type: 'SET_SETTINGS'; payload: AppSettings }
  | { type: 'SET_STATS'; payload: UsageStats }
  | { type: 'SET_LOADING'; payload: boolean }
  | { type: 'SET_ERROR'; payload: string | null };

// Initial State
const initialState: AppState = {
  isInitialized: false,
  proxyStatus: {
    isRunning: false,
    port: 8080,
    requestCount: 0,
    errorCount: 0,
  },
  quotas: [],
  agents: [],
  settings: {
    appMode: 'full',
    theme: 'system',
    language: 'en',
    autoStartProxy: true,
    startMinimized: false,
    showMenuBarIcon: true,
    menuBarQuotaItems: ['gemini', 'claude', 'openai'],
    quotaAlertThreshold: 20,
    enableNotifications: true,
    checkForUpdates: true,
  },
  stats: null,
  isLoading: true,
  error: null,
};

// Reducer
function appReducer(state: AppState, action: AppAction): AppState {
  switch (action.type) {
    case 'SET_INITIALIZED':
      return { ...state, isInitialized: action.payload };
    case 'SET_PROXY_STATUS':
      return { ...state, proxyStatus: action.payload };
    case 'SET_QUOTAS':
      return { ...state, quotas: action.payload };
    case 'UPDATE_QUOTA': {
      const index = state.quotas.findIndex(q => q.providerId === action.payload.providerId);
      if (index >= 0) {
        const newQuotas = [...state.quotas];
        newQuotas[index] = action.payload;
        return { ...state, quotas: newQuotas };
      }
      return { ...state, quotas: [...state.quotas, action.payload] };
    }
    case 'SET_AGENTS':
      return { ...state, agents: action.payload };
    case 'SET_SETTINGS':
      return { ...state, settings: action.payload };
    case 'SET_STATS':
      return { ...state, stats: action.payload };
    case 'SET_LOADING':
      return { ...state, isLoading: action.payload };
    case 'SET_ERROR':
      return { ...state, error: action.payload };
    default:
      return state;
  }
}

// Context
interface AppContextType {
  state: AppState;
  dispatch: React.Dispatch<AppAction>;
  actions: {
    startProxy: () => Promise<void>;
    stopProxy: () => Promise<void>;
    refreshQuotas: () => Promise<void>;
    detectAgents: () => Promise<void>;
    updateSettings: (settings: Partial<AppSettings>) => Promise<void>;
  };
}

const AppContext = createContext<AppContextType | null>(null);

// Provider
export function AppProvider({ children }: { children: ReactNode }): JSX.Element {
  const [state, dispatch] = useReducer(appReducer, initialState);

  // Initialize app
  useEffect(() => {
    const init = async (): Promise<void> => {
      try {
        dispatch({ type: 'SET_LOADING', payload: true });

        // Load settings
        const settings = await window.electron.settings.get();
        dispatch({ type: 'SET_SETTINGS', payload: settings as AppSettings });

        // Load proxy status
        const proxyStatus = await window.electron.proxy.getStatus();
        dispatch({ type: 'SET_PROXY_STATUS', payload: proxyStatus as ProxyStatus });

        // Load quotas
        const quotas = await window.electron.quota.getAll();
        dispatch({ type: 'SET_QUOTAS', payload: quotas as QuotaInfo[] });

        // Load agents
        const agents = await window.electron.agent.getAll();
        dispatch({ type: 'SET_AGENTS', payload: agents as CLIAgent[] });

        // Load stats
        const stats = await window.electron.stats.get();
        dispatch({ type: 'SET_STATS', payload: stats as UsageStats });

        dispatch({ type: 'SET_INITIALIZED', payload: true });
      } catch (error) {
        console.error('Failed to initialize app:', error);
        dispatch({ type: 'SET_ERROR', payload: 'Failed to initialize app' });
      } finally {
        dispatch({ type: 'SET_LOADING', payload: false });
      }
    };

    void init();
  }, []);

  // Subscribe to IPC events
  useEffect(() => {
    const unsubscribeStatus = window.electron.proxy.onStatusChanged((status) => {
      dispatch({ type: 'SET_PROXY_STATUS', payload: status as ProxyStatus });
    });

    const unsubscribeQuota = window.electron.quota.onUpdated((quota) => {
      dispatch({ type: 'UPDATE_QUOTA', payload: quota as QuotaInfo });
    });

    return () => {
      unsubscribeStatus();
      unsubscribeQuota();
    };
  }, []);

  // Apply theme
  useEffect(() => {
    const applyTheme = (): void => {
      const { theme } = state.settings;
      const isDark =
        theme === 'dark' ||
        (theme === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches);

      document.documentElement.classList.toggle('dark', isDark);
    };

    applyTheme();

    // Listen for system theme changes
    const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
    mediaQuery.addEventListener('change', applyTheme);

    return () => {
      mediaQuery.removeEventListener('change', applyTheme);
    };
  }, [state.settings.theme]);

  // Actions
  const actions = {
    startProxy: async (): Promise<void> => {
      try {
        const result = await window.electron.proxy.start();
        if (!result.success) {
          dispatch({ type: 'SET_ERROR', payload: result.error || 'Failed to start proxy' });
        }
      } catch (error) {
        dispatch({ type: 'SET_ERROR', payload: 'Failed to start proxy' });
      }
    },

    stopProxy: async (): Promise<void> => {
      try {
        const result = await window.electron.proxy.stop();
        if (!result.success) {
          dispatch({ type: 'SET_ERROR', payload: result.error || 'Failed to stop proxy' });
        }
      } catch (error) {
        dispatch({ type: 'SET_ERROR', payload: 'Failed to stop proxy' });
      }
    },

    refreshQuotas: async (): Promise<void> => {
      try {
        await window.electron.quota.refresh('all');
        const quotas = await window.electron.quota.getAll();
        dispatch({ type: 'SET_QUOTAS', payload: quotas as QuotaInfo[] });
      } catch (error) {
        dispatch({ type: 'SET_ERROR', payload: 'Failed to refresh quotas' });
      }
    },

    detectAgents: async (): Promise<void> => {
      try {
        const agents = await window.electron.agent.getAll();
        dispatch({ type: 'SET_AGENTS', payload: agents as CLIAgent[] });
      } catch (error) {
        dispatch({ type: 'SET_ERROR', payload: 'Failed to detect agents' });
      }
    },

    updateSettings: async (settings: Partial<AppSettings>): Promise<void> => {
      try {
        await window.electron.settings.update(settings);
        const updatedSettings = await window.electron.settings.get();
        dispatch({ type: 'SET_SETTINGS', payload: updatedSettings as AppSettings });
      } catch (error) {
        dispatch({ type: 'SET_ERROR', payload: 'Failed to update settings' });
      }
    },
  };

  return (
    <AppContext.Provider value={{ state, dispatch, actions }}>
      {children}
    </AppContext.Provider>
  );
}

// Hook
export function useApp(): AppContextType {
  const context = useContext(AppContext);
  if (!context) {
    throw new Error('useApp must be used within AppProvider');
  }
  return context;
}
