import { useApp } from '../store/AppContext';
import type { AppSettings } from '@shared/types';

export default function Settings(): JSX.Element {
  const { state, actions } = useApp();
  const { settings, proxyStatus } = state;

  const handleSettingChange = async (key: keyof AppSettings, value: unknown): Promise<void> => {
    await actions.updateSettings({ [key]: value });
  };

  return (
    <div className="space-y-6 max-w-2xl">
      {/* Header */}
      <div>
        <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Settings</h1>
        <p className="text-gray-500 dark:text-gray-400">
          Configure Quotio preferences and behavior
        </p>
      </div>

      {/* General Settings */}
      <section className="bg-white dark:bg-gray-800 rounded-xl p-6 shadow-sm border border-gray-200 dark:border-gray-700">
        <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">General</h2>

        <div className="space-y-4">
          {/* App Mode */}
          <div className="flex items-center justify-between">
            <div>
              <label className="font-medium text-gray-900 dark:text-white">App Mode</label>
              <p className="text-sm text-gray-500 dark:text-gray-400">
                Choose how Quotio operates
              </p>
            </div>
            <select
              value={settings.appMode}
              onChange={(e) => void handleSettingChange('appMode', e.target.value)}
              className="px-3 py-2 bg-gray-100 dark:bg-gray-700 border-0 rounded-lg text-gray-900 dark:text-white"
            >
              <option value="full">Full Mode (Proxy + Quotas)</option>
              <option value="quota-only">Quota Only Mode</option>
            </select>
          </div>

          {/* Theme */}
          <div className="flex items-center justify-between">
            <div>
              <label className="font-medium text-gray-900 dark:text-white">Theme</label>
              <p className="text-sm text-gray-500 dark:text-gray-400">
                Choose your preferred appearance
              </p>
            </div>
            <select
              value={settings.theme}
              onChange={(e) => void handleSettingChange('theme', e.target.value)}
              className="px-3 py-2 bg-gray-100 dark:bg-gray-700 border-0 rounded-lg text-gray-900 dark:text-white"
            >
              <option value="system">System</option>
              <option value="light">Light</option>
              <option value="dark">Dark</option>
            </select>
          </div>

          {/* Language */}
          <div className="flex items-center justify-between">
            <div>
              <label className="font-medium text-gray-900 dark:text-white">Language</label>
              <p className="text-sm text-gray-500 dark:text-gray-400">
                Interface language
              </p>
            </div>
            <select
              value={settings.language}
              onChange={(e) => void handleSettingChange('language', e.target.value)}
              className="px-3 py-2 bg-gray-100 dark:bg-gray-700 border-0 rounded-lg text-gray-900 dark:text-white"
            >
              <option value="en">English</option>
              <option value="vi">Tiếng Việt</option>
            </select>
          </div>
        </div>
      </section>

      {/* Proxy Settings */}
      <section className="bg-white dark:bg-gray-800 rounded-xl p-6 shadow-sm border border-gray-200 dark:border-gray-700">
        <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Proxy</h2>

        <div className="space-y-4">
          {/* Auto Start */}
          <div className="flex items-center justify-between">
            <div>
              <label className="font-medium text-gray-900 dark:text-white">Auto Start Proxy</label>
              <p className="text-sm text-gray-500 dark:text-gray-400">
                Start proxy automatically when app launches
              </p>
            </div>
            <button
              onClick={() => void handleSettingChange('autoStartProxy', !settings.autoStartProxy)}
              className={`w-12 h-6 rounded-full transition-colors ${
                settings.autoStartProxy ? 'bg-primary-500' : 'bg-gray-300 dark:bg-gray-600'
              }`}
            >
              <div
                className={`w-5 h-5 bg-white rounded-full shadow transition-transform ${
                  settings.autoStartProxy ? 'translate-x-6' : 'translate-x-0.5'
                }`}
              />
            </button>
          </div>

          {/* Port Display */}
          <div className="flex items-center justify-between">
            <div>
              <label className="font-medium text-gray-900 dark:text-white">Proxy Port</label>
              <p className="text-sm text-gray-500 dark:text-gray-400">
                Current proxy port
              </p>
            </div>
            <span className="px-3 py-2 bg-gray-100 dark:bg-gray-700 rounded-lg text-gray-900 dark:text-white font-mono">
              {proxyStatus.port}
            </span>
          </div>
        </div>
      </section>

      {/* Notifications */}
      <section className="bg-white dark:bg-gray-800 rounded-xl p-6 shadow-sm border border-gray-200 dark:border-gray-700">
        <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Notifications</h2>

        <div className="space-y-4">
          {/* Enable Notifications */}
          <div className="flex items-center justify-between">
            <div>
              <label className="font-medium text-gray-900 dark:text-white">Enable Notifications</label>
              <p className="text-sm text-gray-500 dark:text-gray-400">
                Show system notifications for alerts
              </p>
            </div>
            <button
              onClick={() => void handleSettingChange('enableNotifications', !settings.enableNotifications)}
              className={`w-12 h-6 rounded-full transition-colors ${
                settings.enableNotifications ? 'bg-primary-500' : 'bg-gray-300 dark:bg-gray-600'
              }`}
            >
              <div
                className={`w-5 h-5 bg-white rounded-full shadow transition-transform ${
                  settings.enableNotifications ? 'translate-x-6' : 'translate-x-0.5'
                }`}
              />
            </button>
          </div>

          {/* Quota Alert Threshold */}
          <div className="flex items-center justify-between">
            <div>
              <label className="font-medium text-gray-900 dark:text-white">Quota Alert Threshold</label>
              <p className="text-sm text-gray-500 dark:text-gray-400">
                Alert when quota falls below this percentage
              </p>
            </div>
            <div className="flex items-center gap-2">
              <input
                type="range"
                min="5"
                max="50"
                value={settings.quotaAlertThreshold}
                onChange={(e) => void handleSettingChange('quotaAlertThreshold', parseInt(e.target.value))}
                className="w-24"
              />
              <span className="w-12 text-right text-gray-900 dark:text-white">
                {settings.quotaAlertThreshold}%
              </span>
            </div>
          </div>
        </div>
      </section>

      {/* Menu Bar */}
      <section className="bg-white dark:bg-gray-800 rounded-xl p-6 shadow-sm border border-gray-200 dark:border-gray-700">
        <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Menu Bar</h2>

        <div className="space-y-4">
          {/* Show Menu Bar Icon */}
          <div className="flex items-center justify-between">
            <div>
              <label className="font-medium text-gray-900 dark:text-white">Show Menu Bar Icon</label>
              <p className="text-sm text-gray-500 dark:text-gray-400">
                Display Quotio in the menu bar
              </p>
            </div>
            <button
              onClick={() => void handleSettingChange('showMenuBarIcon', !settings.showMenuBarIcon)}
              className={`w-12 h-6 rounded-full transition-colors ${
                settings.showMenuBarIcon ? 'bg-primary-500' : 'bg-gray-300 dark:bg-gray-600'
              }`}
            >
              <div
                className={`w-5 h-5 bg-white rounded-full shadow transition-transform ${
                  settings.showMenuBarIcon ? 'translate-x-6' : 'translate-x-0.5'
                }`}
              />
            </button>
          </div>

          {/* Start Minimized */}
          <div className="flex items-center justify-between">
            <div>
              <label className="font-medium text-gray-900 dark:text-white">Start Minimized</label>
              <p className="text-sm text-gray-500 dark:text-gray-400">
                Launch app minimized to menu bar
              </p>
            </div>
            <button
              onClick={() => void handleSettingChange('startMinimized', !settings.startMinimized)}
              className={`w-12 h-6 rounded-full transition-colors ${
                settings.startMinimized ? 'bg-primary-500' : 'bg-gray-300 dark:bg-gray-600'
              }`}
            >
              <div
                className={`w-5 h-5 bg-white rounded-full shadow transition-transform ${
                  settings.startMinimized ? 'translate-x-6' : 'translate-x-0.5'
                }`}
              />
            </button>
          </div>
        </div>
      </section>

      {/* Updates */}
      <section className="bg-white dark:bg-gray-800 rounded-xl p-6 shadow-sm border border-gray-200 dark:border-gray-700">
        <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Updates</h2>

        <div className="flex items-center justify-between">
          <div>
            <label className="font-medium text-gray-900 dark:text-white">Check for Updates</label>
            <p className="text-sm text-gray-500 dark:text-gray-400">
              Automatically check for new versions
            </p>
          </div>
          <button
            onClick={() => void handleSettingChange('checkForUpdates', !settings.checkForUpdates)}
            className={`w-12 h-6 rounded-full transition-colors ${
              settings.checkForUpdates ? 'bg-primary-500' : 'bg-gray-300 dark:bg-gray-600'
            }`}
          >
            <div
              className={`w-5 h-5 bg-white rounded-full shadow transition-transform ${
                settings.checkForUpdates ? 'translate-x-6' : 'translate-x-0.5'
              }`}
            />
          </button>
        </div>
      </section>

      {/* About */}
      <section className="bg-white dark:bg-gray-800 rounded-xl p-6 shadow-sm border border-gray-200 dark:border-gray-700">
        <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">About</h2>
        <div className="space-y-2 text-sm text-gray-600 dark:text-gray-400">
          <p><strong>Version:</strong> 1.0.0 (Electron)</p>
          <p><strong>Platform:</strong> {window.electron.platform.isMac ? 'macOS' : window.electron.platform.isWindows ? 'Windows' : 'Linux'}</p>
          <p><strong>Electron:</strong> Built with security best practices</p>
        </div>
      </section>
    </div>
  );
}
