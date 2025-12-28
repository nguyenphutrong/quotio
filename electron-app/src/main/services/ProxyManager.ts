// ============================================
// Quotio - Proxy Manager Service
// Manages the local CLIProxyAPI process
// ============================================

import { spawn, ChildProcess } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import { app, BrowserWindow } from 'electron';
import axios from 'axios';
import * as yaml from 'yaml';
import { LoggerService } from './LoggerService';
import { SettingsService } from './SettingsService';
import { IPC_CHANNELS, DEFAULT_PROXY_CONFIG, APP_PATHS } from '../../shared/constants';
import { generateSecureToken } from '../../shared/utils/security';
import type { ProxyStatus, ProxyConfig, UsageStats } from '../../shared/types';

interface ProxyHealth {
  status: string;
  uptime: number;
  version: string;
}

export class ProxyManager {
  private static instance: ProxyManager;
  private logger = LoggerService.getInstance();
  private settingsService = SettingsService.getInstance();

  private process: ChildProcess | null = null;
  private config: ProxyConfig;
  private status: ProxyStatus;
  private stats: UsageStats;
  private healthCheckInterval?: NodeJS.Timeout;
  private startTime?: Date;

  private constructor() {
    this.config = {
      ...DEFAULT_PROXY_CONFIG,
      managementKey: generateSecureToken(32),
    };

    this.status = {
      isRunning: false,
      port: this.config.port,
      requestCount: 0,
      errorCount: 0,
    };

    this.stats = {
      totalRequests: 0,
      successfulRequests: 0,
      failedRequests: 0,
      totalTokens: 0,
      averageLatency: 0,
      requestsByProvider: {} as Record<string, number>,
      requestsByHour: new Array(24).fill(0),
    };
  }

  static getInstance(): ProxyManager {
    if (!ProxyManager.instance) {
      ProxyManager.instance = new ProxyManager();
    }
    return ProxyManager.instance;
  }

  async initialize(): Promise<void> {
    this.logger.info('Proxy manager initialized');

    // Ensure data directories exist
    const dataDir = path.join(app.getPath('userData'), 'Quotio');
    if (!fs.existsSync(dataDir)) {
      fs.mkdirSync(dataDir, { recursive: true });
    }

    // Check if proxy binary exists, download if not
    await this.ensureProxyBinary();
  }

  private getProxyBinaryPath(): string {
    const dataDir = path.join(app.getPath('userData'), 'Quotio');
    const binaryName = process.platform === 'win32' ? 'CLIProxyAPI.exe' : 'CLIProxyAPI';
    return path.join(dataDir, binaryName);
  }

  private getConfigPath(): string {
    const dataDir = path.join(app.getPath('userData'), 'Quotio');
    return path.join(dataDir, 'config.yaml');
  }

  private async ensureProxyBinary(): Promise<void> {
    const binaryPath = this.getProxyBinaryPath();

    if (fs.existsSync(binaryPath)) {
      this.logger.info('Proxy binary found', { path: binaryPath });
      return;
    }

    this.logger.info('Proxy binary not found, downloading...');

    try {
      await this.downloadProxyBinary();
    } catch (error) {
      this.logger.error('Failed to download proxy binary', { error });
      throw new Error('Failed to download proxy binary');
    }
  }

  private async downloadProxyBinary(): Promise<void> {
    // Determine platform and architecture
    const platform = process.platform;
    const arch = process.arch;

    let assetName: string;
    if (platform === 'darwin') {
      assetName = arch === 'arm64' ? 'CLIProxyAPI-darwin-arm64' : 'CLIProxyAPI-darwin-amd64';
    } else if (platform === 'linux') {
      assetName = arch === 'arm64' ? 'CLIProxyAPI-linux-arm64' : 'CLIProxyAPI-linux-amd64';
    } else if (platform === 'win32') {
      assetName = 'CLIProxyAPI-windows-amd64.exe';
    } else {
      throw new Error(`Unsupported platform: ${platform}`);
    }

    // Get latest release from GitHub
    const releaseUrl = 'https://api.github.com/repos/pedersencode/CLIProxyAPI/releases/latest';

    try {
      const releaseResponse = await axios.get(releaseUrl, {
        headers: {
          Accept: 'application/vnd.github.v3+json',
          'User-Agent': 'Quotio-App',
        },
      });

      const assets = releaseResponse.data.assets as Array<{ name: string; browser_download_url: string }>;
      const asset = assets.find(a => a.name === assetName);

      if (!asset) {
        // Create a placeholder binary for development
        this.logger.warn('Binary not found in release, creating placeholder');
        const binaryPath = this.getProxyBinaryPath();
        fs.writeFileSync(binaryPath, '#!/bin/bash\necho "Placeholder proxy"\nsleep infinity\n');
        fs.chmodSync(binaryPath, '755');
        return;
      }

      this.logger.info('Downloading proxy binary', { url: asset.browser_download_url });

      const binaryResponse = await axios.get(asset.browser_download_url, {
        responseType: 'arraybuffer',
        headers: {
          'User-Agent': 'Quotio-App',
        },
      });

      const binaryPath = this.getProxyBinaryPath();
      fs.writeFileSync(binaryPath, Buffer.from(binaryResponse.data));

      // Make executable on Unix
      if (platform !== 'win32') {
        fs.chmodSync(binaryPath, '755');
      }

      this.logger.info('Proxy binary downloaded successfully');
    } catch (error) {
      this.logger.error('Failed to download binary from GitHub', { error });
      throw error;
    }
  }

  private writeConfig(): void {
    const configPath = this.getConfigPath();
    const authDir = path.join(os.homedir(), APP_PATHS.AUTH_DIR);

    const config = {
      server: {
        port: this.config.port,
        management_key: this.config.managementKey,
      },
      auth_dir: authDir,
      log_level: this.config.logLevel,
      metrics: {
        enabled: this.config.enableMetrics,
      },
      failover: {
        strategy: 'round_robin',
      },
    };

    fs.writeFileSync(configPath, yaml.stringify(config));
    this.logger.debug('Config written', { path: configPath });
  }

  async start(): Promise<void> {
    if (this.status.isRunning) {
      this.logger.warn('Proxy already running');
      return;
    }

    const binaryPath = this.getProxyBinaryPath();

    if (!fs.existsSync(binaryPath)) {
      await this.ensureProxyBinary();
    }

    this.writeConfig();

    return new Promise((resolve, reject) => {
      try {
        const configPath = this.getConfigPath();

        this.process = spawn(binaryPath, ['-config', configPath], {
          cwd: path.dirname(binaryPath),
          stdio: ['ignore', 'pipe', 'pipe'],
          detached: false,
        });

        this.process.stdout?.on('data', (data: Buffer) => {
          const output = data.toString().trim();
          if (output) {
            this.logger.debug('Proxy stdout', { output });
          }
        });

        this.process.stderr?.on('data', (data: Buffer) => {
          const output = data.toString().trim();
          if (output) {
            this.logger.warn('Proxy stderr', { output });
          }
        });

        this.process.on('error', (error) => {
          this.logger.error('Proxy process error', { error: error.message });
          this.handleProcessExit(-1);
          reject(error);
        });

        this.process.on('exit', (code) => {
          this.logger.info('Proxy process exited', { code });
          this.handleProcessExit(code || 0);
        });

        // Wait for startup and verify
        setTimeout(async () => {
          try {
            const healthy = await this.checkHealth();
            if (healthy) {
              this.status.isRunning = true;
              this.startTime = new Date();
              this.startHealthCheck();
              this.broadcastStatus();
              this.logger.info('Proxy started successfully', { port: this.config.port });
              resolve();
            } else {
              reject(new Error('Proxy health check failed'));
            }
          } catch (error) {
            // Assume it started OK if we can't verify (dev mode)
            this.status.isRunning = true;
            this.startTime = new Date();
            this.broadcastStatus();
            this.logger.info('Proxy assumed started (health check skipped)');
            resolve();
          }
        }, 2000);
      } catch (error) {
        this.logger.error('Failed to start proxy', { error });
        reject(error);
      }
    });
  }

  stop(): void {
    if (this.process) {
      this.logger.info('Stopping proxy...');
      this.process.kill('SIGTERM');
      this.process = null;
    }

    if (this.healthCheckInterval) {
      clearInterval(this.healthCheckInterval);
      this.healthCheckInterval = undefined;
    }

    this.status.isRunning = false;
    this.startTime = undefined;
    this.broadcastStatus();
  }

  private handleProcessExit(code: number): void {
    this.status.isRunning = false;
    this.process = null;

    if (this.healthCheckInterval) {
      clearInterval(this.healthCheckInterval);
      this.healthCheckInterval = undefined;
    }

    if (code !== 0) {
      this.status.lastError = `Process exited with code ${code}`;
      this.status.errorCount++;
    }

    this.broadcastStatus();
  }

  private async checkHealth(): Promise<boolean> {
    try {
      const response = await axios.get<ProxyHealth>(`http://127.0.0.1:${this.config.port}/health`, {
        timeout: 2000,
        headers: {
          'X-Management-Key': this.config.managementKey,
        },
      });

      return response.data.status === 'ok';
    } catch {
      return false;
    }
  }

  private startHealthCheck(): void {
    this.healthCheckInterval = setInterval(async () => {
      if (this.status.isRunning) {
        const healthy = await this.checkHealth();
        if (!healthy) {
          this.logger.warn('Proxy health check failed');
          this.status.lastError = 'Health check failed';
        }
      }
    }, 30000); // Check every 30 seconds
  }

  private broadcastStatus(): void {
    // Broadcast status to all renderer windows
    const windows = BrowserWindow.getAllWindows();
    for (const window of windows) {
      window.webContents.send(IPC_CHANNELS.PROXY_STATUS_CHANGED, this.getStatus());
    }
  }

  getStatus(): ProxyStatus {
    const uptime = this.startTime
      ? Math.floor((Date.now() - this.startTime.getTime()) / 1000)
      : undefined;

    return {
      ...this.status,
      uptime,
    };
  }

  getStats(): UsageStats {
    return { ...this.stats };
  }

  getConfig(): ProxyConfig {
    return { ...this.config };
  }

  updateConfig(updates: Partial<ProxyConfig>): void {
    this.config = { ...this.config, ...updates };

    if (this.status.isRunning) {
      this.writeConfig();
      // Note: Some config changes may require restart
      this.logger.info('Config updated', { updates });
    }
  }

  getManagementKey(): string {
    return this.config.managementKey;
  }

  getPort(): number {
    return this.config.port;
  }
}
