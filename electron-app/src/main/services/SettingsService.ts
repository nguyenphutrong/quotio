// ============================================
// Quotio - Settings Service
// Secure settings storage with validation
// ============================================

import Store from 'electron-store';
import { DEFAULT_SETTINGS } from '../../shared/constants';
import type { AppSettings } from '../../shared/types';
import { LoggerService } from './LoggerService';
import { safeJsonParse } from '../../shared/utils/security';

interface SettingsSchema {
  settings: AppSettings;
  hasCompletedOnboarding: boolean;
  apiKeys: string[];
  lastUpdateCheck: number;
}

export class SettingsService {
  private static instance: SettingsService;
  private store: Store<SettingsSchema>;
  private logger = LoggerService.getInstance();

  private constructor() {
    // Initialize electron-store with schema validation
    this.store = new Store<SettingsSchema>({
      name: 'quotio-settings',
      defaults: {
        settings: DEFAULT_SETTINGS,
        hasCompletedOnboarding: false,
        apiKeys: [],
        lastUpdateCheck: 0,
      },
      // Encrypt sensitive data
      encryptionKey: 'quotio-secure-storage-key-v1',
      // Schema for validation
      schema: {
        settings: {
          type: 'object',
          properties: {
            appMode: { type: 'string', enum: ['full', 'quota-only'] },
            theme: { type: 'string', enum: ['light', 'dark', 'system'] },
            language: { type: 'string', enum: ['en', 'vi'] },
            autoStartProxy: { type: 'boolean' },
            startMinimized: { type: 'boolean' },
            showMenuBarIcon: { type: 'boolean' },
            menuBarQuotaItems: { type: 'array', items: { type: 'string' } },
            quotaAlertThreshold: { type: 'number', minimum: 0, maximum: 100 },
            enableNotifications: { type: 'boolean' },
            checkForUpdates: { type: 'boolean' },
          },
        },
        hasCompletedOnboarding: { type: 'boolean' },
        apiKeys: { type: 'array', items: { type: 'string' } },
        lastUpdateCheck: { type: 'number' },
      },
    });
  }

  static getInstance(): SettingsService {
    if (!SettingsService.instance) {
      SettingsService.instance = new SettingsService();
    }
    return SettingsService.instance;
  }

  async initialize(): Promise<void> {
    this.logger.info('Settings service initialized');

    // Validate stored settings
    const settings = this.store.get('settings');
    if (!this.validateSettings(settings)) {
      this.logger.warn('Invalid settings found, resetting to defaults');
      this.store.set('settings', DEFAULT_SETTINGS);
    }
  }

  private validateSettings(settings: unknown): settings is AppSettings {
    if (!settings || typeof settings !== 'object') {
      return false;
    }

    const s = settings as Record<string, unknown>;

    // Validate required fields
    const validModes = ['full', 'quota-only'];
    const validThemes = ['light', 'dark', 'system'];
    const validLanguages = ['en', 'vi'];

    if (!validModes.includes(s.appMode as string)) return false;
    if (!validThemes.includes(s.theme as string)) return false;
    if (!validLanguages.includes(s.language as string)) return false;
    if (typeof s.autoStartProxy !== 'boolean') return false;
    if (typeof s.startMinimized !== 'boolean') return false;
    if (typeof s.showMenuBarIcon !== 'boolean') return false;
    if (!Array.isArray(s.menuBarQuotaItems)) return false;
    if (typeof s.quotaAlertThreshold !== 'number') return false;
    if (typeof s.enableNotifications !== 'boolean') return false;
    if (typeof s.checkForUpdates !== 'boolean') return false;

    return true;
  }

  getSettings(): AppSettings {
    return this.store.get('settings');
  }

  updateSettings(updates: Partial<AppSettings> | Record<string, unknown>): void {
    const currentSettings = this.store.get('settings');

    // Sanitize and validate updates
    const sanitizedUpdates: Partial<AppSettings> = {};

    if ('appMode' in updates && ['full', 'quota-only'].includes(updates.appMode as string)) {
      sanitizedUpdates.appMode = updates.appMode as 'full' | 'quota-only';
    }
    if ('theme' in updates && ['light', 'dark', 'system'].includes(updates.theme as string)) {
      sanitizedUpdates.theme = updates.theme as 'light' | 'dark' | 'system';
    }
    if ('language' in updates && ['en', 'vi'].includes(updates.language as string)) {
      sanitizedUpdates.language = updates.language as 'en' | 'vi';
    }
    if ('autoStartProxy' in updates && typeof updates.autoStartProxy === 'boolean') {
      sanitizedUpdates.autoStartProxy = updates.autoStartProxy;
    }
    if ('startMinimized' in updates && typeof updates.startMinimized === 'boolean') {
      sanitizedUpdates.startMinimized = updates.startMinimized;
    }
    if ('showMenuBarIcon' in updates && typeof updates.showMenuBarIcon === 'boolean') {
      sanitizedUpdates.showMenuBarIcon = updates.showMenuBarIcon;
    }
    if ('menuBarQuotaItems' in updates && Array.isArray(updates.menuBarQuotaItems)) {
      sanitizedUpdates.menuBarQuotaItems = updates.menuBarQuotaItems as AppSettings['menuBarQuotaItems'];
    }
    if ('quotaAlertThreshold' in updates && typeof updates.quotaAlertThreshold === 'number') {
      sanitizedUpdates.quotaAlertThreshold = Math.max(0, Math.min(100, updates.quotaAlertThreshold));
    }
    if ('enableNotifications' in updates && typeof updates.enableNotifications === 'boolean') {
      sanitizedUpdates.enableNotifications = updates.enableNotifications;
    }
    if ('checkForUpdates' in updates && typeof updates.checkForUpdates === 'boolean') {
      sanitizedUpdates.checkForUpdates = updates.checkForUpdates;
    }

    const newSettings = { ...currentSettings, ...sanitizedUpdates };
    this.store.set('settings', newSettings);

    this.logger.info('Settings updated', { updates: sanitizedUpdates });
  }

  hasCompletedOnboarding(): boolean {
    return this.store.get('hasCompletedOnboarding');
  }

  setOnboardingComplete(complete: boolean): void {
    this.store.set('hasCompletedOnboarding', complete);
  }

  getApiKeys(): string[] {
    return this.store.get('apiKeys');
  }

  addApiKey(key: string): void {
    const keys = this.store.get('apiKeys');
    if (!keys.includes(key)) {
      keys.push(key);
      this.store.set('apiKeys', keys);
    }
  }

  removeApiKey(key: string): void {
    const keys = this.store.get('apiKeys').filter(k => k !== key);
    this.store.set('apiKeys', keys);
  }

  getLastUpdateCheck(): number {
    return this.store.get('lastUpdateCheck');
  }

  setLastUpdateCheck(timestamp: number): void {
    this.store.set('lastUpdateCheck', timestamp);
  }

  reset(): void {
    this.store.set('settings', DEFAULT_SETTINGS);
    this.logger.info('Settings reset to defaults');
  }

  export(): string {
    // Export settings without sensitive data
    const settings = this.store.get('settings');
    return JSON.stringify(settings, null, 2);
  }

  import(settingsJson: string): boolean {
    const parsed = safeJsonParse<AppSettings>(settingsJson);
    if (parsed && this.validateSettings(parsed)) {
      this.store.set('settings', parsed);
      this.logger.info('Settings imported successfully');
      return true;
    }
    this.logger.warn('Failed to import settings: invalid format');
    return false;
  }
}
