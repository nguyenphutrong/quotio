// ============================================
// Quotio - Shared Types
// ============================================

// AI Provider Types
export type AIProviderType =
  | 'gemini'
  | 'claude'
  | 'openai'
  | 'copilot'
  | 'cursor'
  | 'vertex'
  | 'qwen'
  | 'antigravity'
  | 'iflow'
  | 'kiro';

export interface AIProvider {
  id: string;
  type: AIProviderType;
  name: string;
  email?: string;
  isActive: boolean;
  authMethod: 'oauth' | 'apikey' | 'cli' | 'serviceaccount';
  authFilePath?: string;
  lastSync?: Date;
}

// Quota Types
export interface QuotaInfo {
  providerId: string;
  providerType: AIProviderType;
  used: number;
  total: number;
  percentage: number;
  resetDate?: Date;
  models?: ModelQuota[];
  lastUpdated: Date;
}

export interface ModelQuota {
  modelId: string;
  modelName: string;
  used: number;
  total: number;
  percentage: number;
}

// Proxy Types
export interface ProxyStatus {
  isRunning: boolean;
  port: number;
  uptime?: number;
  requestCount: number;
  errorCount: number;
  lastError?: string;
}

export interface ProxyConfig {
  port: number;
  managementKey: string;
  autoStart: boolean;
  logLevel: 'debug' | 'info' | 'warn' | 'error';
  enableMetrics: boolean;
}

// Usage Statistics
export interface UsageStats {
  totalRequests: number;
  successfulRequests: number;
  failedRequests: number;
  totalTokens: number;
  averageLatency: number;
  requestsByProvider: Record<AIProviderType, number>;
  requestsByHour: number[];
}

// CLI Agent Types
export interface CLIAgent {
  id: string;
  name: string;
  type: 'claude-code' | 'codex-cli' | 'gemini-cli' | 'amp-cli' | 'opencode' | 'factory-droid';
  isInstalled: boolean;
  configPath?: string;
  version?: string;
  isConfigured: boolean;
}

export interface AgentConfiguration {
  agentId: string;
  proxyUrl: string;
  apiKey: string;
  modelSlots?: ModelSlot[];
}

export interface ModelSlot {
  slotName: string;
  provider: AIProviderType;
  modelId: string;
}

// App Settings
export interface AppSettings {
  appMode: 'full' | 'quota-only';
  theme: 'light' | 'dark' | 'system';
  language: 'en' | 'vi';
  autoStartProxy: boolean;
  startMinimized: boolean;
  showMenuBarIcon: boolean;
  menuBarQuotaItems: AIProviderType[];
  quotaAlertThreshold: number;
  enableNotifications: boolean;
  checkForUpdates: boolean;
}

// IPC Channel Types
export interface IPCChannels {
  // Main -> Renderer
  'proxy:status-changed': ProxyStatus;
  'quota:updated': QuotaInfo;
  'notification:show': { title: string; body: string; type: 'info' | 'warning' | 'error' };
  'agent:detected': CLIAgent;

  // Renderer -> Main
  'proxy:start': void;
  'proxy:stop': void;
  'quota:refresh': AIProviderType | 'all';
  'settings:get': void;
  'settings:update': Partial<AppSettings>;
  'agent:configure': AgentConfiguration;
  'auth:start': AIProviderType;
  'window:open-main': void;
}

// API Response Types
export interface APIResponse<T> {
  success: boolean;
  data?: T;
  error?: {
    code: string;
    message: string;
  };
}

// Auth File Types (for direct file reading)
export interface AuthFile {
  provider: AIProviderType;
  path: string;
  email?: string;
  expiresAt?: Date;
  isValid: boolean;
}

// Log Entry
export interface LogEntry {
  timestamp: Date;
  level: 'debug' | 'info' | 'warn' | 'error';
  source: string;
  message: string;
  data?: Record<string, unknown>;
}

// Menu Bar Item
export interface MenuBarQuotaItem {
  provider: AIProviderType;
  percentage: number;
  color: 'green' | 'yellow' | 'red';
  icon: string;
}

// App State
export interface AppState {
  isInitialized: boolean;
  hasCompletedOnboarding: boolean;
  proxyStatus: ProxyStatus;
  providers: AIProvider[];
  quotas: QuotaInfo[];
  agents: CLIAgent[];
  settings: AppSettings;
  stats: UsageStats;
  logs: LogEntry[];
}
