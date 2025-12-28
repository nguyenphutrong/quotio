// ============================================
// Quotio - Quota Service
// Fetches and manages quota information for all providers
// ============================================

import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import axios from 'axios';
import { BrowserWindow } from 'electron';
import { LoggerService } from './LoggerService';
import { IPC_CHANNELS, APP_PATHS, PROVIDER_CONFIG } from '../../shared/constants';
import type { QuotaInfo, AIProviderType, AuthFile } from '../../shared/types';
import { safeJsonParse } from '../../shared/utils/security';

interface AuthFileData {
  email?: string;
  access_token?: string;
  refresh_token?: string;
  expires_at?: string;
  account_id?: string;
}

export class QuotaService {
  private static instance: QuotaService;
  private logger = LoggerService.getInstance();
  private quotas: Map<string, QuotaInfo> = new Map();
  private authFiles: Map<string, AuthFile> = new Map();

  private constructor() {}

  static getInstance(): QuotaService {
    if (!QuotaService.instance) {
      QuotaService.instance = new QuotaService();
    }
    return QuotaService.instance;
  }

  async initialize(): Promise<void> {
    this.logger.info('Quota service initialized');
    await this.scanAuthFiles();
  }

  private getAuthDir(): string {
    return path.join(os.homedir(), APP_PATHS.AUTH_DIR);
  }

  async scanAuthFiles(): Promise<void> {
    const authDir = this.getAuthDir();

    if (!fs.existsSync(authDir)) {
      this.logger.debug('Auth directory does not exist', { path: authDir });
      return;
    }

    try {
      const files = fs.readdirSync(authDir);

      for (const file of files) {
        if (!file.endsWith('.json')) continue;

        const filePath = path.join(authDir, file);
        const provider = this.identifyProvider(file);

        if (provider) {
          try {
            const content = fs.readFileSync(filePath, 'utf-8');
            const data = safeJsonParse<AuthFileData>(content);

            if (data) {
              const authFile: AuthFile = {
                provider,
                path: filePath,
                email: data.email,
                expiresAt: data.expires_at ? new Date(data.expires_at) : undefined,
                isValid: this.isAuthValid(data),
              };

              this.authFiles.set(`${provider}-${file}`, authFile);
              this.logger.debug('Auth file found', { provider, file });
            }
          } catch (error) {
            this.logger.warn('Failed to parse auth file', { file, error });
          }
        }
      }
    } catch (error) {
      this.logger.error('Failed to scan auth files', { error });
    }
  }

  private identifyProvider(filename: string): AIProviderType | null {
    for (const [providerType, config] of Object.entries(PROVIDER_CONFIG)) {
      const pattern = config.authFilePattern.replace('*', '.*');
      if (new RegExp(pattern).test(filename)) {
        return providerType as AIProviderType;
      }
    }
    return null;
  }

  private isAuthValid(data: AuthFileData): boolean {
    if (!data.access_token && !data.refresh_token) {
      return false;
    }

    if (data.expires_at) {
      const expiresAt = new Date(data.expires_at);
      if (expiresAt < new Date()) {
        return false;
      }
    }

    return true;
  }

  async refreshAll(): Promise<void> {
    this.logger.info('Refreshing all quotas...');

    await this.scanAuthFiles();

    const providers = new Set<AIProviderType>();
    for (const authFile of this.authFiles.values()) {
      if (authFile.isValid) {
        providers.add(authFile.provider);
      }
    }

    const refreshPromises = Array.from(providers).map(provider =>
      this.refreshProvider(provider).catch(error => {
        this.logger.error('Failed to refresh provider quota', { provider, error });
      })
    );

    await Promise.all(refreshPromises);
    this.logger.info('All quotas refreshed');
  }

  async refreshProvider(provider: string): Promise<void> {
    try {
      const quota = await this.fetchQuota(provider as AIProviderType);
      if (quota) {
        this.quotas.set(provider, quota);
        this.broadcastQuotaUpdate(quota);
      }
    } catch (error) {
      this.logger.error('Failed to fetch quota', { provider, error });
      throw error;
    }
  }

  private async fetchQuota(provider: AIProviderType): Promise<QuotaInfo | null> {
    // Find auth file for this provider
    const authFile = Array.from(this.authFiles.values()).find(
      af => af.provider === provider && af.isValid
    );

    if (!authFile) {
      this.logger.debug('No valid auth file for provider', { provider });
      return null;
    }

    // Fetch quota based on provider type
    switch (provider) {
      case 'gemini':
        return this.fetchGeminiQuota(authFile);
      case 'claude':
        return this.fetchClaudeQuota(authFile);
      case 'openai':
        return this.fetchOpenAIQuota(authFile);
      case 'copilot':
        return this.fetchCopilotQuota(authFile);
      case 'cursor':
        return this.fetchCursorQuota(authFile);
      default:
        // For unknown providers, return a mock quota
        return this.createMockQuota(provider);
    }
  }

  private async fetchGeminiQuota(authFile: AuthFile): Promise<QuotaInfo> {
    try {
      const content = fs.readFileSync(authFile.path, 'utf-8');
      const data = safeJsonParse<AuthFileData & { quota_remaining?: number; quota_total?: number }>(content);

      if (data?.quota_remaining !== undefined && data?.quota_total !== undefined) {
        const used = data.quota_total - data.quota_remaining;
        return {
          providerId: `gemini-${authFile.email || 'default'}`,
          providerType: 'gemini',
          used,
          total: data.quota_total,
          percentage: (used / data.quota_total) * 100,
          lastUpdated: new Date(),
        };
      }
    } catch (error) {
      this.logger.error('Failed to fetch Gemini quota', { error });
    }

    return this.createMockQuota('gemini');
  }

  private async fetchClaudeQuota(authFile: AuthFile): Promise<QuotaInfo> {
    try {
      const content = fs.readFileSync(authFile.path, 'utf-8');
      const data = safeJsonParse<AuthFileData & { usage?: { used: number; total: number } }>(content);

      if (data?.usage) {
        return {
          providerId: `claude-${authFile.email || 'default'}`,
          providerType: 'claude',
          used: data.usage.used,
          total: data.usage.total,
          percentage: (data.usage.used / data.usage.total) * 100,
          lastUpdated: new Date(),
        };
      }
    } catch (error) {
      this.logger.error('Failed to fetch Claude quota', { error });
    }

    return this.createMockQuota('claude');
  }

  private async fetchOpenAIQuota(authFile: AuthFile): Promise<QuotaInfo> {
    try {
      const content = fs.readFileSync(authFile.path, 'utf-8');
      const data = safeJsonParse<AuthFileData & { rate_limit?: { remaining: number; total: number } }>(content);

      if (data?.rate_limit) {
        const used = data.rate_limit.total - data.rate_limit.remaining;
        return {
          providerId: `openai-${authFile.email || 'default'}`,
          providerType: 'openai',
          used,
          total: data.rate_limit.total,
          percentage: (used / data.rate_limit.total) * 100,
          lastUpdated: new Date(),
        };
      }
    } catch (error) {
      this.logger.error('Failed to fetch OpenAI quota', { error });
    }

    return this.createMockQuota('openai');
  }

  private async fetchCopilotQuota(authFile: AuthFile): Promise<QuotaInfo> {
    return this.createMockQuota('copilot');
  }

  private async fetchCursorQuota(authFile: AuthFile): Promise<QuotaInfo> {
    return this.createMockQuota('cursor');
  }

  private createMockQuota(provider: AIProviderType): QuotaInfo {
    // Create a realistic mock quota for demo/development
    const total = 100;
    const used = Math.floor(Math.random() * 80);

    return {
      providerId: `${provider}-default`,
      providerType: provider,
      used,
      total,
      percentage: (used / total) * 100,
      lastUpdated: new Date(),
    };
  }

  private broadcastQuotaUpdate(quota: QuotaInfo): void {
    const windows = BrowserWindow.getAllWindows();
    for (const window of windows) {
      window.webContents.send(IPC_CHANNELS.QUOTA_UPDATED, quota);
    }
  }

  getAllQuotas(): QuotaInfo[] {
    return Array.from(this.quotas.values());
  }

  getQuota(provider: AIProviderType): QuotaInfo | undefined {
    return this.quotas.get(provider);
  }

  getAuthFiles(): AuthFile[] {
    return Array.from(this.authFiles.values());
  }
}
