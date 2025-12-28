// ============================================
// Quotio - Shared Constants
// ============================================

// IPC Channel Names (prefixed for security)
export const IPC_CHANNELS = {
  // Proxy Management
  PROXY_START: 'quotio:proxy:start',
  PROXY_STOP: 'quotio:proxy:stop',
  PROXY_STATUS: 'quotio:proxy:status',
  PROXY_STATUS_CHANGED: 'quotio:proxy:status-changed',

  // Quota Management
  QUOTA_REFRESH: 'quotio:quota:refresh',
  QUOTA_GET_ALL: 'quotio:quota:get-all',
  QUOTA_UPDATED: 'quotio:quota:updated',

  // Provider Management
  PROVIDER_ADD: 'quotio:provider:add',
  PROVIDER_REMOVE: 'quotio:provider:remove',
  PROVIDER_GET_ALL: 'quotio:provider:get-all',
  PROVIDER_AUTH_START: 'quotio:provider:auth-start',
  PROVIDER_AUTH_CALLBACK: 'quotio:provider:auth-callback',

  // Agent Management
  AGENT_DETECT: 'quotio:agent:detect',
  AGENT_CONFIGURE: 'quotio:agent:configure',
  AGENT_GET_ALL: 'quotio:agent:get-all',

  // Settings
  SETTINGS_GET: 'quotio:settings:get',
  SETTINGS_UPDATE: 'quotio:settings:update',

  // Window Management
  WINDOW_OPEN_MAIN: 'quotio:window:open-main',
  WINDOW_MINIMIZE: 'quotio:window:minimize',
  WINDOW_CLOSE: 'quotio:window:close',

  // Notifications
  NOTIFICATION_SHOW: 'quotio:notification:show',

  // Logs
  LOG_GET: 'quotio:log:get',
  LOG_CLEAR: 'quotio:log:clear',

  // Stats
  STATS_GET: 'quotio:stats:get',
  STATS_RESET: 'quotio:stats:reset',

  // App State
  APP_STATE_GET: 'quotio:app:state:get',
  APP_READY: 'quotio:app:ready',
  APP_QUIT: 'quotio:app:quit',
} as const;

// Provider Configuration
export const PROVIDER_CONFIG = {
  gemini: {
    name: 'Google Gemini',
    authMethod: 'oauth' as const,
    authFilePattern: 'gemini-cli-*.json',
    oauthUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
    color: '#4285f4',
    icon: 'gemini',
  },
  claude: {
    name: 'Anthropic Claude',
    authMethod: 'oauth' as const,
    authFilePattern: 'claude-*.json',
    oauthUrl: 'https://console.anthropic.com/oauth',
    color: '#cc785c',
    icon: 'claude',
  },
  openai: {
    name: 'OpenAI',
    authMethod: 'oauth' as const,
    authFilePattern: 'codex-*.json',
    oauthUrl: 'https://platform.openai.com/oauth',
    color: '#10a37f',
    icon: 'openai',
  },
  copilot: {
    name: 'GitHub Copilot',
    authMethod: 'cli' as const,
    authFilePattern: 'github-copilot-*.json',
    color: '#000000',
    icon: 'copilot',
  },
  cursor: {
    name: 'Cursor',
    authMethod: 'oauth' as const,
    authFilePattern: 'cursor-*.json',
    color: '#7c3aed',
    icon: 'cursor',
  },
  vertex: {
    name: 'Vertex AI',
    authMethod: 'serviceaccount' as const,
    authFilePattern: 'vertex-*.json',
    color: '#4285f4',
    icon: 'vertex',
  },
  qwen: {
    name: 'Qwen Code',
    authMethod: 'oauth' as const,
    authFilePattern: 'qwen-*.json',
    color: '#6366f1',
    icon: 'qwen',
  },
  antigravity: {
    name: 'Antigravity',
    authMethod: 'oauth' as const,
    authFilePattern: 'antigravity-*.json',
    color: '#ff6b35',
    icon: 'antigravity',
  },
  iflow: {
    name: 'iFlow',
    authMethod: 'oauth' as const,
    authFilePattern: 'iflow-*.json',
    color: '#06b6d4',
    icon: 'iflow',
  },
  kiro: {
    name: 'Kiro / CodeWhisperer',
    authMethod: 'cli' as const,
    authFilePattern: 'kiro-*.json',
    color: '#f97316',
    icon: 'kiro',
  },
} as const;

// Agent Configuration
export const AGENT_CONFIG = {
  'claude-code': {
    name: 'Claude Code',
    detectCommand: 'claude --version',
    configFile: '.claude.json',
    envVar: 'ANTHROPIC_API_KEY',
  },
  'codex-cli': {
    name: 'Codex CLI',
    detectCommand: 'codex --version',
    configFile: '.codex.json',
    envVar: 'OPENAI_API_KEY',
  },
  'gemini-cli': {
    name: 'Gemini CLI',
    detectCommand: 'gemini --version',
    configFile: '.gemini.json',
    envVar: 'GEMINI_API_KEY',
  },
  'amp-cli': {
    name: 'Amp CLI',
    detectCommand: 'amp --version',
    configFile: '.amp.json',
    envVar: 'AMP_API_KEY',
  },
  'opencode': {
    name: 'OpenCode',
    detectCommand: 'opencode --version',
    configFile: '.opencode.json',
    envVar: 'OPENCODE_API_KEY',
  },
  'factory-droid': {
    name: 'Factory Droid',
    detectCommand: 'factory-droid --version',
    configFile: '.factory-droid.json',
    envVar: 'FACTORY_DROID_API_KEY',
  },
} as const;

// Default Settings
export const DEFAULT_SETTINGS = {
  appMode: 'full' as const,
  theme: 'system' as const,
  language: 'en' as const,
  autoStartProxy: true,
  startMinimized: false,
  showMenuBarIcon: true,
  menuBarQuotaItems: ['gemini', 'claude', 'openai'] as const,
  quotaAlertThreshold: 20,
  enableNotifications: true,
  checkForUpdates: true,
};

// Default Proxy Config
export const DEFAULT_PROXY_CONFIG = {
  port: 8080,
  managementKey: '',
  autoStart: true,
  logLevel: 'info' as const,
  enableMetrics: true,
};

// App Paths
export const APP_PATHS = {
  AUTH_DIR: '.cli-proxy-api',
  CONFIG_DIR: 'Quotio',
  PROXY_BINARY: 'CLIProxyAPI',
  LOGS_DIR: 'logs',
};

// Security Constants
export const SECURITY = {
  // Allowed external domains for OAuth
  ALLOWED_EXTERNAL_DOMAINS: [
    'accounts.google.com',
    'console.anthropic.com',
    'platform.openai.com',
    'github.com',
    'api.github.com',
  ],

  // CSP Policy
  CSP_POLICY: "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; connect-src 'self' https://api.github.com",

  // Max request size
  MAX_REQUEST_SIZE: 10 * 1024 * 1024, // 10MB

  // Session timeout
  SESSION_TIMEOUT: 30 * 60 * 1000, // 30 minutes
};

// Quota Thresholds for color coding
export const QUOTA_THRESHOLDS = {
  GREEN: 50,  // > 50% remaining
  YELLOW: 20, // > 20% remaining
  RED: 0,     // <= 20% remaining
};

// Refresh Intervals (in ms)
export const REFRESH_INTERVALS = {
  QUOTA: 5 * 60 * 1000,      // 5 minutes
  PROXY_STATUS: 10 * 1000,    // 10 seconds
  STATS: 30 * 1000,           // 30 seconds
  AGENT_DETECT: 60 * 1000,    // 1 minute
};
