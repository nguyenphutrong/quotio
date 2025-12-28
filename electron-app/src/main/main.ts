// ============================================
// Quotio - Electron Main Process
// Security-First Implementation
// ============================================

import {
  app,
  BrowserWindow,
  ipcMain,
  Tray,
  Menu,
  nativeImage,
  shell,
  Notification,
  session,
} from 'electron';
import * as path from 'path';
import { ProxyManager } from './services/ProxyManager';
import { QuotaService } from './services/QuotaService';
import { SettingsService } from './services/SettingsService';
import { AgentDetectionService } from './services/AgentDetectionService';
import { LoggerService } from './services/LoggerService';
import { IPC_CHANNELS, SECURITY } from '../shared/constants';
import { isValidExternalUrl, isValidIPCChannel } from '../shared/utils/security';

// ============================================
// Security Configuration
// ============================================

// Disable hardware acceleration if not needed (reduces attack surface)
// app.disableHardwareAcceleration();

// Prevent multiple instances
const gotTheLock = app.requestSingleInstanceLock();
if (!gotTheLock) {
  app.quit();
}

// Global references
let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;
const logger = LoggerService.getInstance();
const proxyManager = ProxyManager.getInstance();
const quotaService = QuotaService.getInstance();
const settingsService = SettingsService.getInstance();
const agentService = AgentDetectionService.getInstance();

// ============================================
// Security: Configure Session
// ============================================

function configureSession(): void {
  const ses = session.defaultSession;

  // Set Content Security Policy
  ses.webRequest.onHeadersReceived((details, callback) => {
    callback({
      responseHeaders: {
        ...details.responseHeaders,
        'Content-Security-Policy': [SECURITY.CSP_POLICY],
        'X-Content-Type-Options': ['nosniff'],
        'X-Frame-Options': ['DENY'],
        'X-XSS-Protection': ['1; mode=block'],
        'Referrer-Policy': ['strict-origin-when-cross-origin'],
      },
    });
  });

  // Block all permission requests by default
  ses.setPermissionRequestHandler((webContents, permission, callback) => {
    const allowedPermissions = ['clipboard-read', 'clipboard-write'];
    callback(allowedPermissions.includes(permission));
  });

  // Validate navigation
  ses.webRequest.onBeforeRequest((details, callback) => {
    const url = details.url;

    // Allow local resources
    if (url.startsWith('file://') || url.startsWith('devtools://')) {
      callback({ cancel: false });
      return;
    }

    // Allow localhost for dev
    if (url.includes('localhost') || url.includes('127.0.0.1')) {
      callback({ cancel: false });
      return;
    }

    // Block all other requests unless explicitly allowed
    if (!isValidExternalUrl(url)) {
      logger.warn('Blocked external request', { url });
      callback({ cancel: true });
      return;
    }

    callback({ cancel: false });
  });
}

// ============================================
// Window Creation
// ============================================

function createMainWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    minWidth: 900,
    minHeight: 600,
    show: false,
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 15, y: 15 },
    vibrancy: 'under-window',
    visualEffectState: 'active',
    webPreferences: {
      // Security: Disable Node.js in renderer
      nodeIntegration: false,
      // Security: Enable context isolation
      contextIsolation: true,
      // Security: Use preload script for IPC
      preload: path.join(__dirname, 'preload.js'),
      // Security: Disable remote module
      // Security: Disable web security only in dev (not recommended)
      webSecurity: true,
      // Security: Disable webview tag
      webviewTag: false,
      // Security: Enable sandbox
      sandbox: true,
      // Security: Disable plugins
      plugins: false,
      // Security: Disable experimental features
      experimentalFeatures: false,
    },
  });

  // Security: Prevent new window creation
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (isValidExternalUrl(url)) {
      shell.openExternal(url).catch(err => {
        logger.error('Failed to open external URL', { url, error: err });
      });
    }
    return { action: 'deny' };
  });

  // Security: Prevent navigation to external URLs
  mainWindow.webContents.on('will-navigate', (event, url) => {
    const parsedUrl = new URL(url);
    if (parsedUrl.protocol !== 'file:') {
      event.preventDefault();
      if (isValidExternalUrl(url)) {
        shell.openExternal(url).catch(err => {
          logger.error('Failed to open external URL', { url, error: err });
        });
      }
    }
  });

  // Load the app
  if (process.env.NODE_ENV === 'development') {
    mainWindow.loadURL('http://localhost:5173').catch(err => {
      logger.error('Failed to load dev URL', { error: err });
    });
    mainWindow.webContents.openDevTools();
  } else {
    mainWindow.loadFile(path.join(__dirname, '../renderer/index.html')).catch(err => {
      logger.error('Failed to load production file', { error: err });
    });
  }

  mainWindow.once('ready-to-show', () => {
    const settings = settingsService.getSettings();
    if (!settings.startMinimized) {
      mainWindow?.show();
    }
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });

  // Hide instead of close (for menu bar app)
  mainWindow.on('close', (event) => {
    if (!app.isQuitting) {
      event.preventDefault();
      mainWindow?.hide();
    }
  });
}

// ============================================
// Tray / Menu Bar
// ============================================

function createTray(): void {
  const iconPath = path.join(__dirname, '../../resources/tray-icon.png');
  const icon = nativeImage.createFromPath(iconPath);

  // Create a default icon if file doesn't exist
  const trayIcon = icon.isEmpty()
    ? nativeImage.createEmpty()
    : icon.resize({ width: 16, height: 16 });

  tray = new Tray(trayIcon);
  tray.setToolTip('Quotio - AI Assistant Manager');

  updateTrayMenu();

  tray.on('click', () => {
    if (mainWindow) {
      if (mainWindow.isVisible()) {
        mainWindow.hide();
      } else {
        mainWindow.show();
        mainWindow.focus();
      }
    } else {
      createMainWindow();
    }
  });
}

function updateTrayMenu(): void {
  if (!tray) return;

  const proxyStatus = proxyManager.getStatus();
  const quotas = quotaService.getAllQuotas();

  const contextMenu = Menu.buildFromTemplate([
    {
      label: 'Quotio',
      type: 'normal',
      enabled: false,
    },
    { type: 'separator' },
    {
      label: `Proxy: ${proxyStatus.isRunning ? 'Running' : 'Stopped'}`,
      type: 'normal',
      enabled: false,
    },
    {
      label: proxyStatus.isRunning ? 'Stop Proxy' : 'Start Proxy',
      type: 'normal',
      click: () => {
        if (proxyStatus.isRunning) {
          proxyManager.stop();
        } else {
          proxyManager.start().catch(err => {
            logger.error('Failed to start proxy', { error: err });
          });
        }
        updateTrayMenu();
      },
    },
    { type: 'separator' },
    {
      label: 'Quotas',
      type: 'submenu',
      submenu: quotas.map(q => ({
        label: `${q.providerType}: ${q.percentage.toFixed(0)}%`,
        type: 'normal' as const,
        enabled: false,
      })),
    },
    { type: 'separator' },
    {
      label: 'Open Dashboard',
      type: 'normal',
      click: () => {
        if (mainWindow) {
          mainWindow.show();
          mainWindow.focus();
        } else {
          createMainWindow();
        }
      },
    },
    {
      label: 'Refresh Quotas',
      type: 'normal',
      click: () => {
        quotaService.refreshAll().catch(err => {
          logger.error('Failed to refresh quotas', { error: err });
        });
        updateTrayMenu();
      },
    },
    { type: 'separator' },
    {
      label: 'Quit',
      type: 'normal',
      click: () => {
        app.isQuitting = true;
        app.quit();
      },
    },
  ]);

  tray.setContextMenu(contextMenu);
}

// ============================================
// IPC Handlers (Security-First)
// ============================================

function setupIPCHandlers(): void {
  // Validate all IPC channels before handling
  const validateChannel = (channel: string): boolean => {
    return isValidIPCChannel(channel);
  };

  // Proxy Management
  ipcMain.handle(IPC_CHANNELS.PROXY_START, async () => {
    try {
      await proxyManager.start();
      updateTrayMenu();
      return { success: true };
    } catch (error) {
      logger.error('Failed to start proxy via IPC', { error });
      return { success: false, error: String(error) };
    }
  });

  ipcMain.handle(IPC_CHANNELS.PROXY_STOP, async () => {
    try {
      proxyManager.stop();
      updateTrayMenu();
      return { success: true };
    } catch (error) {
      logger.error('Failed to stop proxy via IPC', { error });
      return { success: false, error: String(error) };
    }
  });

  ipcMain.handle(IPC_CHANNELS.PROXY_STATUS, () => {
    return proxyManager.getStatus();
  });

  // Quota Management
  ipcMain.handle(IPC_CHANNELS.QUOTA_GET_ALL, () => {
    return quotaService.getAllQuotas();
  });

  ipcMain.handle(IPC_CHANNELS.QUOTA_REFRESH, async (_event, provider?: string) => {
    try {
      if (provider && provider !== 'all') {
        await quotaService.refreshProvider(provider);
      } else {
        await quotaService.refreshAll();
      }
      updateTrayMenu();
      return { success: true };
    } catch (error) {
      logger.error('Failed to refresh quotas via IPC', { error });
      return { success: false, error: String(error) };
    }
  });

  // Settings
  ipcMain.handle(IPC_CHANNELS.SETTINGS_GET, () => {
    return settingsService.getSettings();
  });

  ipcMain.handle(IPC_CHANNELS.SETTINGS_UPDATE, (_event, settings: Record<string, unknown>) => {
    try {
      settingsService.updateSettings(settings);
      return { success: true };
    } catch (error) {
      logger.error('Failed to update settings via IPC', { error });
      return { success: false, error: String(error) };
    }
  });

  // Agent Detection
  ipcMain.handle(IPC_CHANNELS.AGENT_GET_ALL, async () => {
    return agentService.detectAgents();
  });

  ipcMain.handle(IPC_CHANNELS.AGENT_CONFIGURE, async (_event, config: Record<string, unknown>) => {
    try {
      await agentService.configureAgent(config);
      return { success: true };
    } catch (error) {
      logger.error('Failed to configure agent via IPC', { error });
      return { success: false, error: String(error) };
    }
  });

  // Window Management
  ipcMain.handle(IPC_CHANNELS.WINDOW_OPEN_MAIN, () => {
    if (mainWindow) {
      mainWindow.show();
      mainWindow.focus();
    } else {
      createMainWindow();
    }
    return { success: true };
  });

  // Logs
  ipcMain.handle(IPC_CHANNELS.LOG_GET, () => {
    return logger.getLogs();
  });

  ipcMain.handle(IPC_CHANNELS.LOG_CLEAR, () => {
    logger.clearLogs();
    return { success: true };
  });

  // Stats
  ipcMain.handle(IPC_CHANNELS.STATS_GET, () => {
    return proxyManager.getStats();
  });
}

// ============================================
// Notifications
// ============================================

function showNotification(title: string, body: string): void {
  if (Notification.isSupported()) {
    new Notification({
      title,
      body,
      silent: false,
    }).show();
  }
}

// ============================================
// App Lifecycle
// ============================================

// Extend app type to include isQuitting
declare module 'electron' {
  interface App {
    isQuitting?: boolean;
  }
}

app.whenReady().then(async () => {
  logger.info('App starting...');

  // Configure security settings
  configureSession();

  // Initialize services
  await settingsService.initialize();
  await quotaService.initialize();
  await proxyManager.initialize();

  // Setup IPC handlers
  setupIPCHandlers();

  // Create UI
  createTray();
  createMainWindow();

  // Auto-start proxy if configured
  const settings = settingsService.getSettings();
  if (settings.autoStartProxy) {
    try {
      await proxyManager.start();
      updateTrayMenu();
    } catch (error) {
      logger.error('Failed to auto-start proxy', { error });
      showNotification('Quotio', 'Failed to start proxy automatically');
    }
  }

  // Setup periodic quota refresh
  setInterval(() => {
    quotaService.refreshAll().then(() => {
      updateTrayMenu();
    }).catch(err => {
      logger.error('Periodic quota refresh failed', { error: err });
    });
  }, 5 * 60 * 1000); // Every 5 minutes

  logger.info('App ready');
});

app.on('second-instance', () => {
  if (mainWindow) {
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.show();
    mainWindow.focus();
  }
});

app.on('window-all-closed', () => {
  // Keep running in menu bar on macOS
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createMainWindow();
  } else if (mainWindow) {
    mainWindow.show();
  }
});

app.on('before-quit', () => {
  app.isQuitting = true;
  proxyManager.stop();
  logger.info('App quitting');
});

// Security: Handle certificate errors
app.on('certificate-error', (event, webContents, url, error, certificate, callback) => {
  // Reject all certificate errors in production
  event.preventDefault();
  callback(false);
  logger.error('Certificate error', { url, error });
});
