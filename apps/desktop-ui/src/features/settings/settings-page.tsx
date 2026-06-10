import { Button } from '@quotio/ui/components/button';
import { Input } from '@quotio/ui/components/input';
import { Label } from '@quotio/ui/components/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@quotio/ui/components/select';
import { Switch } from '@quotio/ui/components/switch';
import { type ReactNode, useEffect, useId, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { AdminPageHeader } from '@/components/admin/admin-page-header';
import { Panel } from '@/components/admin/panel';
import { StatusBadge } from '@/components/admin/status-badge';
import { useToast } from '@/components/admin/toast-provider';
import {
  type AdvancedProxySettings,
  type RoutingStrategy,
  sanitizeProxyUrl,
  useAdvancedProxySettingsMutation,
  useAdvancedProxySettingsQuery,
  validateProxyUrl,
} from '@/features/settings/advanced-proxy-api';
import {
  type NativePreferences,
  type NativePreferencesPatch,
  useAdminRuntime,
} from '@/lib/admin/runtime';

const MANAGEMENT_BASE_URL_TARGET = 'Quotio/ManagementBaseUrl';
const MANAGEMENT_KEY_TARGET = 'Quotio/ManagementKey';
const REMOTE_CONNECTION_PANEL_ID = 'remote-management-connection';

type RemoteConnectionState = {
  baseUrl: string;
  keyExists: boolean;
  loading: boolean;
  saving: boolean;
  clearing: boolean;
  error: string | null;
};

const initialState: RemoteConnectionState = {
  baseUrl: '',
  keyExists: false,
  loading: true,
  saving: false,
  clearing: false,
  error: null,
};

type NativePreferencesState = {
  preferences: NativePreferences | null;
  loading: boolean;
  savingKey: keyof NativePreferencesPatch | null;
  checkingUpdates: boolean;
  error: string | null;
};

const initialPreferencesState: NativePreferencesState = {
  preferences: null,
  loading: true,
  savingKey: null,
  checkingUpdates: false,
  error: null,
};

const requestRetryRange = { min: 0, max: 10 };
const maxRetryIntervalRange = { min: 5, max: 300, step: 5 };

function RemoteConnectionPanel() {
  const { t } = useTranslation();
  const toast = useToast();
  const {
    bootstrap,
    confirm,
    credentialDelete,
    credentialRead,
    credentialWrite,
  } = useAdminRuntime();
  const baseUrlId = useId();
  const keyId = useId();
  const [state, setState] = useState(initialState);
  const [keyInput, setKeyInput] = useState('');

  const enabled =
    bootstrap.capabilities.supportsRemoteConnections &&
    bootstrap.capabilities.supportsCredentialStorage;

  useEffect(() => {
    let cancelled = false;

    async function loadCredentials() {
      if (!enabled) {
        setState((current) => ({ ...current, loading: false, error: null }));
        return;
      }

      setState((current) => ({ ...current, loading: true, error: null }));

      try {
        const [baseUrlCredential, keyCredential] = await Promise.all([
          credentialRead({ targetName: MANAGEMENT_BASE_URL_TARGET }),
          credentialRead({ targetName: MANAGEMENT_KEY_TARGET }),
        ]);

        if (cancelled) {
          return;
        }

        setState((current) => ({
          ...current,
          baseUrl: baseUrlCredential.value ?? '',
          keyExists: keyCredential.exists,
          loading: false,
          error: null,
        }));
      } catch (error) {
        if (cancelled) {
          return;
        }

        setState((current) => ({
          ...current,
          loading: false,
          error:
            error instanceof Error ? error.message : t('common.unknownError'),
        }));
      }
    }

    void loadCredentials();

    return () => {
      cancelled = true;
    };
  }, [credentialRead, enabled, t]);

  const save = async () => {
    const baseUrl = state.baseUrl.trim();
    const managementKey = keyInput.trim();

    if (!baseUrl) {
      setState((current) => ({
        ...current,
        error: t('settings.remote.errors.baseUrlRequired'),
      }));
      return;
    }

    setState((current) => ({ ...current, saving: true, error: null }));

    try {
      await credentialWrite({
        targetName: MANAGEMENT_BASE_URL_TARGET,
        value: baseUrl,
      });

      if (managementKey) {
        await credentialWrite({
          targetName: MANAGEMENT_KEY_TARGET,
          value: managementKey,
        });
      }

      setState((current) => ({
        ...current,
        baseUrl,
        keyExists: managementKey ? true : current.keyExists,
        saving: false,
        error: null,
      }));
      setKeyInput('');
      toast.success(t('settings.remote.messages.saved'));
    } catch (error) {
      setState((current) => ({
        ...current,
        saving: false,
        error:
          error instanceof Error ? error.message : t('common.unknownError'),
      }));
    }
  };

  const clear = async () => {
    const accepted = await confirm({
      title: t('settings.remote.clearConfirmTitle'),
      message: t('settings.remote.clearConfirmMessage'),
      confirmLabel: t('settings.remote.actions.clear'),
      cancelLabel: t('common.cancel'),
      destructive: true,
    });

    if (!accepted) {
      return;
    }

    setState((current) => ({ ...current, clearing: true, error: null }));

    try {
      await Promise.all([
        credentialDelete({ targetName: MANAGEMENT_BASE_URL_TARGET }),
        credentialDelete({ targetName: MANAGEMENT_KEY_TARGET }),
      ]);

      setState((current) => ({
        ...current,
        baseUrl: '',
        keyExists: false,
        clearing: false,
        error: null,
      }));
      setKeyInput('');
      toast.success(t('settings.remote.messages.cleared'));
    } catch (error) {
      setState((current) => ({
        ...current,
        clearing: false,
        error:
          error instanceof Error ? error.message : t('common.unknownError'),
      }));
    }
  };

  if (!enabled) {
    return (
      <Panel id={REMOTE_CONNECTION_PANEL_ID}>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h2 className="font-medium text-foreground text-sm">
              {t('settings.remote.title')}
            </h2>
            <p className="mt-1 text-muted-foreground text-sm">
              {t('settings.remote.unsupported')}
            </p>
          </div>
          <StatusBadge>{t('about.status.disabled')}</StatusBadge>
        </div>
      </Panel>
    );
  }

  const disabled = state.loading || state.saving || state.clearing;

  return (
    <Panel id={REMOTE_CONNECTION_PANEL_ID}>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h2 className="font-medium text-foreground text-sm">
            {t('settings.remote.title')}
          </h2>
          <p className="mt-1 max-w-2xl text-muted-foreground text-sm">
            {t('settings.remote.description')}
          </p>
        </div>
        <StatusBadge tone={state.keyExists ? 'success' : 'neutral'}>
          {state.keyExists
            ? t('settings.remote.status.configured')
            : t('settings.remote.status.notConfigured')}
        </StatusBadge>
      </div>

      <div className="mt-5 grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
        <div className="space-y-2">
          <Label htmlFor={baseUrlId}>{t('settings.remote.baseUrlLabel')}</Label>
          <Input
            id={baseUrlId}
            autoComplete="off"
            inputMode="url"
            placeholder="http://127.0.0.1:8386"
            value={state.baseUrl}
            disabled={disabled}
            onChange={(event) =>
              setState((current) => ({
                ...current,
                baseUrl: event.target.value,
                error: null,
              }))
            }
          />
        </div>

        <div className="space-y-2">
          <Label htmlFor={keyId}>{t('settings.remote.keyLabel')}</Label>
          <Input
            id={keyId}
            autoComplete="new-password"
            type="password"
            placeholder={
              state.keyExists
                ? t('settings.remote.keyStoredPlaceholder')
                : t('settings.remote.keyPlaceholder')
            }
            value={keyInput}
            disabled={disabled}
            onChange={(event) => {
              setKeyInput(event.target.value);
              setState((current) => ({ ...current, error: null }));
            }}
          />
        </div>
      </div>

      {state.error ? (
        <p className="mt-3 text-danger text-sm">{state.error}</p>
      ) : null}

      <div className="mt-5 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
        <Button
          type="button"
          variant="outline"
          disabled={disabled || (!state.baseUrl && !state.keyExists)}
          onClick={() => void clear()}
        >
          {state.clearing
            ? t('settings.remote.actions.clearing')
            : t('settings.remote.actions.clear')}
        </Button>
        <Button type="button" disabled={disabled} onClick={() => void save()}>
          {state.saving
            ? t('settings.remote.actions.saving')
            : t('settings.remote.actions.save')}
        </Button>
      </div>
    </Panel>
  );
}

function NativePreferencesPanel() {
  const { i18n, t } = useTranslation();
  const toast = useToast();
  const {
    bootstrap,
    openExternal,
    preferencesRead,
    preferencesWrite,
    updatesCheck,
  } = useAdminRuntime();
  const [state, setState] = useState(initialPreferencesState);
  const [authDirDraft, setAuthDirDraft] = useState('');
  const [proxyPortDraft, setProxyPortDraft] = useState('');

  const enabled = bootstrap.capabilities.supportsNativePreferences;
  const isMacHost = bootstrap.platform === 'macos';
  const supportsLaunchAtLogin =
    bootstrap.platform === 'macos' || bootstrap.platform === 'windows';

  useEffect(() => {
    let cancelled = false;

    async function loadPreferences() {
      if (!enabled) {
        setState((current) => ({ ...current, loading: false, error: null }));
        return;
      }

      setState((current) => ({ ...current, loading: true, error: null }));

      try {
        const preferences = await preferencesRead();
        if (cancelled) {
          return;
        }
        setState({
          preferences,
          loading: false,
          savingKey: null,
          checkingUpdates: false,
          error: null,
        });
      } catch (error) {
        if (cancelled) {
          return;
        }
        setState((current) => ({
          ...current,
          loading: false,
          error:
            error instanceof Error ? error.message : t('common.unknownError'),
        }));
      }
    }

    void loadPreferences();

    return () => {
      cancelled = true;
    };
  }, [enabled, preferencesRead, t]);

  useEffect(() => {
    setAuthDirDraft(state.preferences?.authDir ?? '');
    setProxyPortDraft(
      state.preferences?.proxyPort ? String(state.preferences.proxyPort) : '',
    );
  }, [state.preferences?.authDir, state.preferences?.proxyPort]);

  const savePreference = async <Key extends keyof NativePreferencesPatch>(
    key: Key,
    value: NonNullable<NativePreferencesPatch[Key]>,
  ) => {
    setState((current) => ({
      ...current,
      savingKey: key,
      error: null,
    }));

    try {
      const preferences = await preferencesWrite({ [key]: value });
      setState({
        preferences,
        loading: false,
        savingKey: null,
        checkingUpdates: false,
        error: null,
      });
      if (key === 'language') {
        await i18n.changeLanguage(String(value));
      }
      toast.success(t('settings.native.messages.saved'));
    } catch (error) {
      setState((current) => ({
        ...current,
        savingKey: null,
        error:
          error instanceof Error ? error.message : t('common.unknownError'),
      }));
    }
  };

  const checkForUpdates = async () => {
    setState((current) => ({
      ...current,
      checkingUpdates: true,
      error: null,
    }));

    try {
      const preferences = await updatesCheck();
      setState({
        preferences,
        loading: false,
        savingKey: null,
        checkingUpdates: preferences.isCheckingForUpdates,
        error: null,
      });
      toast.success(t('settings.native.messages.updateCheckStarted'));
    } catch (error) {
      setState((current) => ({
        ...current,
        checkingUpdates: false,
        error:
          error instanceof Error ? error.message : t('common.unknownError'),
      }));
    }
  };

  const openLaunchAtLoginSettings = async () => {
    try {
      await openExternal('ms-settings:startupapps');
    } catch (error) {
      setState((current) => ({
        ...current,
        error:
          error instanceof Error ? error.message : t('common.unknownError'),
      }));
    }
  };

  const scrollToRemoteConnection = () => {
    document
      .getElementById(REMOTE_CONNECTION_PANEL_ID)
      ?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };

  const saveProxyPort = async () => {
    const port = Number(proxyPortDraft);
    if (!Number.isInteger(port) || port < 1 || port > 65_535) {
      setState((current) => ({
        ...current,
        error: t('settings.native.errors.proxyPortInvalid'),
      }));
      return;
    }

    await savePreference('proxyPort', port);
  };

  const saveAuthDir = async (value = authDirDraft) => {
    const path = value.trim();
    if (!path) {
      setState((current) => ({
        ...current,
        error: t('settings.native.errors.authDirRequired'),
      }));
      return;
    }

    await savePreference('authDir', path);
  };

  if (!enabled) {
    return (
      <Panel>
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h2 className="font-medium text-foreground text-sm">
              {t('settings.native.title')}
            </h2>
            <p className="mt-1 text-muted-foreground text-sm">
              {t('settings.native.unsupported')}
            </p>
          </div>
          <StatusBadge>{t('about.status.disabled')}</StatusBadge>
        </div>
      </Panel>
    );
  }

  const preferences = state.preferences;
  const disabled = state.loading || state.savingKey !== null || !preferences;
  const supportsLocalProxy = bootstrap.capabilities.supportsLocalProxy;
  const supportsPortConfig = bootstrap.capabilities.supportsPortConfig;
  const localModeEnabled =
    supportsLocalProxy && preferences?.operatingMode === 'local';
  const supportsTrayBehavior = bootstrap.capabilities.supportsTrayBehavior;
  const showWindowsSetup =
    bootstrap.platform === 'windows' &&
    !bootstrap.capabilities.supportsNativeOnboarding &&
    preferences;

  return (
    <Panel>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h2 className="font-medium text-foreground text-sm">
            {t('settings.native.title')}
          </h2>
          <p className="mt-1 max-w-2xl text-muted-foreground text-sm">
            {t('settings.native.description')}
          </p>
        </div>
        <StatusBadge tone={state.error ? 'danger' : 'success'}>
          {state.loading
            ? t('settings.native.status.loading')
            : t('settings.native.status.ready')}
        </StatusBadge>
      </div>

      {showWindowsSetup ? (
        <div className="mt-5 rounded-lg border border-border bg-muted/20 p-4">
          <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <h3 className="font-medium text-foreground text-sm">
                {t('settings.native.setup.title')}
              </h3>
              <p className="mt-1 max-w-2xl text-muted-foreground text-xs">
                {t('settings.native.setup.description')}
              </p>
            </div>
            <div className="flex flex-wrap gap-2">
              {preferences.launchAtLoginCanOpenSystemSettings ? (
                <Button
                  size="sm"
                  type="button"
                  variant="outline"
                  onClick={() => void openLaunchAtLoginSettings()}
                >
                  {t('settings.native.actions.openStartupSettings')}
                </Button>
              ) : null}
              <Button
                size="sm"
                type="button"
                variant="outline"
                onClick={scrollToRemoteConnection}
              >
                {t('settings.native.setup.actions.remoteConnection')}
              </Button>
            </div>
          </div>
          <div className="mt-4 grid gap-3 md:grid-cols-2">
            <PreferenceStat
              label={t('settings.native.setup.startupApps')}
              value={
                preferences.launchAtLogin
                  ? t('about.status.enabled')
                  : t('about.status.disabled')
              }
            />
            <PreferenceStat
              label={t('settings.native.setup.remoteConnection')}
              value={
                preferences.remoteConfigured
                  ? t('settings.remote.status.configured')
                  : t('settings.remote.status.notConfigured')
              }
            />
          </div>
        </div>
      ) : null}

      <div className="mt-5 grid gap-4 md:grid-cols-2">
        <PreferenceField
          label={t('settings.native.fields.operatingMode')}
          hint={
            preferences?.remoteConfigured
              ? t('settings.native.hints.operatingMode')
              : t('settings.native.hints.remoteNotConfigured')
          }
        >
          <Select
            value={
              supportsLocalProxy
                ? (preferences?.operatingMode ?? 'local')
                : 'remote'
            }
            disabled={disabled}
            onValueChange={(value) =>
              void savePreference(
                'operatingMode',
                value as NativePreferences['operatingMode'],
              )
            }
          >
            <SelectTrigger className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="local" disabled={!supportsLocalProxy}>
                {t('about.operatingMode.local')}
              </SelectItem>
              <SelectItem
                value="remote"
                disabled={!preferences?.remoteConfigured}
              >
                {t('about.operatingMode.remote')}
              </SelectItem>
            </SelectContent>
          </Select>
        </PreferenceField>

        <PreferenceField
          label={t('settings.native.fields.language')}
          hint={t('settings.native.hints.language')}
        >
          <Select
            value={preferences?.language ?? bootstrap.locale}
            disabled={disabled}
            onValueChange={(value) =>
              void savePreference(
                'language',
                value as NativePreferences['language'],
              )
            }
          >
            <SelectTrigger className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="en">English</SelectItem>
              <SelectItem value="vi">Tiếng Việt</SelectItem>
              <SelectItem value="zh-Hans">简体中文</SelectItem>
            </SelectContent>
          </Select>
        </PreferenceField>

        <PreferenceField
          label={t('settings.native.fields.appearance')}
          hint={t('settings.native.hints.appearance')}
        >
          <Select
            value={preferences?.appearance ?? bootstrap.appearance}
            disabled={disabled}
            onValueChange={(value) =>
              void savePreference(
                'appearance',
                value as NativePreferences['appearance'],
              )
            }
          >
            <SelectTrigger className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="system">
                {t('about.appearance.system')}
              </SelectItem>
              <SelectItem value="light">
                {t('about.appearance.light')}
              </SelectItem>
              <SelectItem value="dark">{t('about.appearance.dark')}</SelectItem>
            </SelectContent>
          </Select>
        </PreferenceField>

        {supportsLaunchAtLogin ? (
          <PreferenceField
            label={t('settings.native.fields.launchAtLogin')}
            hint={t('settings.native.hints.launchAtLogin')}
          >
            <div className="flex min-h-9 items-center justify-between gap-4 rounded-md border border-border px-3 py-1">
              <span className="text-muted-foreground text-sm">
                {preferences?.launchAtLogin
                  ? t('about.status.enabled')
                  : t('about.status.disabled')}
              </span>
              <div className="flex items-center gap-2">
                {preferences?.launchAtLoginCanOpenSystemSettings ? (
                  <Button
                    size="sm"
                    type="button"
                    variant="ghost"
                    onClick={() => void openLaunchAtLoginSettings()}
                  >
                    {t('settings.native.actions.openStartupSettings')}
                  </Button>
                ) : null}
                <Switch
                  checked={preferences?.launchAtLogin ?? false}
                  disabled={disabled}
                  onCheckedChange={(checked) =>
                    void savePreference('launchAtLogin', checked)
                  }
                />
              </div>
            </div>
          </PreferenceField>
        ) : null}

        {supportsTrayBehavior ? (
          <PreferenceField
            label={t('settings.native.fields.closeToTray')}
            hint={t('settings.native.hints.closeToTray')}
          >
            <div className="flex min-h-9 items-center justify-between gap-4 rounded-md border border-border px-3 py-1">
              <span className="text-muted-foreground text-sm">
                {preferences?.closeToTray
                  ? t('about.status.enabled')
                  : t('about.status.disabled')}
              </span>
              <Switch
                checked={preferences?.closeToTray ?? true}
                disabled={disabled}
                onCheckedChange={(checked) =>
                  void savePreference('closeToTray', checked)
                }
              />
            </div>
          </PreferenceField>
        ) : null}
      </div>

      <div className="mt-6 grid gap-5 xl:grid-cols-2">
        {localModeEnabled ? (
          <PreferenceGroup
            description={t('settings.native.groups.localProxy.description')}
            title={t('settings.native.groups.localProxy.title')}
          >
            <div className="grid gap-3 sm:grid-cols-2">
              <PreferenceStat
                label={t('settings.native.fields.proxyStatus')}
                value={
                  preferences?.proxyRunning
                    ? t('overview.proxyRuntime.status.running')
                    : t('overview.proxyRuntime.status.stopped')
                }
              />
              <PreferenceStat
                label={t('settings.native.fields.proxyEndpoint')}
                value={
                  preferences?.proxyEndpoint ||
                  t('overview.proxyRuntime.noEndpoint')
                }
              />
              <PreferenceStat
                label={t('settings.native.fields.proxyServerKind')}
                value={preferences?.proxyServerKind ?? 'cpa-plusplus'}
              />
              <PreferenceStat
                label={t('settings.native.fields.proxyServerVersion')}
                value={
                  preferences?.proxyServerVersion ??
                  t('settings.native.values.notDetected')
                }
              />
              <PreferenceStat
                label={t('settings.native.fields.proxyInstallStatus')}
                value={proxyInstallStatusLabel(
                  preferences?.proxyInstallStatus,
                  t,
                )}
              />
              <PreferenceStat
                label={t('settings.native.fields.proxyActiveBinaryPath')}
                value={preferences?.proxyActiveBinaryPath ?? ''}
              />
            </div>

            {supportsPortConfig ? (
              <PreferenceField
                hint={t('settings.native.hints.proxyPort')}
                label={t('settings.native.fields.proxyPort')}
              >
                <div className="flex gap-2">
                  <Input
                    inputMode="numeric"
                    min={1}
                    max={65_535}
                    type="number"
                    value={proxyPortDraft}
                    disabled={disabled}
                    onChange={(event) => {
                      setProxyPortDraft(event.target.value);
                      setState((current) => ({ ...current, error: null }));
                    }}
                    onKeyDown={(event) => {
                      if (event.key === 'Enter') {
                        void saveProxyPort();
                      }
                    }}
                  />
                  <Button
                    type="button"
                    disabled={disabled}
                    onClick={() => void saveProxyPort()}
                  >
                    {t('common.save')}
                  </Button>
                </div>
              </PreferenceField>
            ) : null}

            {isMacHost ? (
              <>
                <SwitchField
                  checked={preferences?.allowNetworkAccess ?? false}
                  disabled={disabled}
                  label={t('settings.native.fields.allowNetworkAccess')}
                  onCheckedChange={(checked) =>
                    void savePreference('allowNetworkAccess', checked)
                  }
                />

                {preferences?.allowNetworkAccess ? (
                  <p className="text-danger text-xs">
                    {t('settings.native.hints.allowNetworkAccessWarning')}
                  </p>
                ) : null}

                <SwitchField
                  checked={preferences?.autoStartTunnel ?? false}
                  disabled={disabled || !preferences?.tunnelInstalled}
                  label={t('settings.native.fields.autoStartTunnel')}
                  onCheckedChange={(checked) =>
                    void savePreference('autoStartTunnel', checked)
                  }
                />
                <SwitchField
                  checked={preferences?.autoRestartTunnel ?? false}
                  disabled={disabled || !preferences?.tunnelInstalled}
                  label={t('settings.native.fields.autoRestartTunnel')}
                  onCheckedChange={(checked) =>
                    void savePreference('autoRestartTunnel', checked)
                  }
                />

                <PreferenceField
                  hint={t('settings.native.hints.authDir')}
                  label={t('settings.native.fields.authDir')}
                >
                  <div className="flex flex-col gap-2 sm:flex-row">
                    <Input
                      className="font-mono text-xs"
                      value={authDirDraft}
                      disabled={disabled}
                      onChange={(event) => {
                        setAuthDirDraft(event.target.value);
                        setState((current) => ({ ...current, error: null }));
                      }}
                      onKeyDown={(event) => {
                        if (event.key === 'Enter') {
                          void saveAuthDir();
                        }
                      }}
                    />
                    <div className="flex gap-2">
                      <Button
                        type="button"
                        disabled={disabled}
                        onClick={() => void saveAuthDir()}
                      >
                        {t('common.save')}
                      </Button>
                      <Button
                        type="button"
                        variant="outline"
                        disabled={disabled || !preferences?.defaultAuthDir}
                        onClick={() => {
                          const defaultAuthDir =
                            preferences?.defaultAuthDir ?? '';
                          setAuthDirDraft(defaultAuthDir);
                          void saveAuthDir(defaultAuthDir);
                        }}
                      >
                        {t('settings.native.actions.reset')}
                      </Button>
                    </div>
                  </div>
                </PreferenceField>

                <PreferenceStat
                  label={t('settings.native.fields.proxyConfigPath')}
                  value={preferences?.proxyConfigPath ?? ''}
                />
              </>
            ) : null}
          </PreferenceGroup>
        ) : null}

        {isMacHost ? (
          <PreferenceGroup
            description={t('settings.native.groups.notifications.description')}
            title={t('settings.native.groups.notifications.title')}
          >
            <SwitchField
              checked={preferences?.notificationsEnabled ?? false}
              disabled={disabled}
              label={t('settings.native.fields.notificationsEnabled')}
              onCheckedChange={(checked) =>
                void savePreference('notificationsEnabled', checked)
              }
            />
            <SwitchField
              checked={preferences?.notifyOnQuotaLow ?? false}
              disabled={disabled || !preferences?.notificationsEnabled}
              label={t('settings.native.fields.notifyOnQuotaLow')}
              onCheckedChange={(checked) =>
                void savePreference('notifyOnQuotaLow', checked)
              }
            />
            <SwitchField
              checked={preferences?.notifyOnCooling ?? false}
              disabled={disabled || !preferences?.notificationsEnabled}
              label={t('settings.native.fields.notifyOnCooling')}
              onCheckedChange={(checked) =>
                void savePreference('notifyOnCooling', checked)
              }
            />
            <SwitchField
              checked={preferences?.notifyOnProxyCrash ?? false}
              disabled={disabled || !preferences?.notificationsEnabled}
              label={t('settings.native.fields.notifyOnProxyCrash')}
              onCheckedChange={(checked) =>
                void savePreference('notifyOnProxyCrash', checked)
              }
            />
            <PreferenceField
              hint={t('settings.native.hints.quotaAlertThreshold')}
              label={t('settings.native.fields.quotaAlertThreshold')}
            >
              <Select
                value={String(preferences?.quotaAlertThreshold ?? 20)}
                disabled={disabled || !preferences?.notificationsEnabled}
                onValueChange={(value) =>
                  void savePreference(
                    'quotaAlertThreshold',
                    Number(value) as NativePreferences['quotaAlertThreshold'],
                  )
                }
              >
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="10">10%</SelectItem>
                  <SelectItem value="20">20%</SelectItem>
                  <SelectItem value="30">30%</SelectItem>
                  <SelectItem value="50">50%</SelectItem>
                </SelectContent>
              </Select>
            </PreferenceField>
          </PreferenceGroup>
        ) : null}

        {isMacHost ? (
          <PreferenceGroup
            description={t('settings.native.groups.quota.description')}
            title={t('settings.native.groups.quota.title')}
          >
            <PreferenceField
              hint={t('settings.native.hints.quotaDisplayMode')}
              label={t('settings.native.fields.quotaDisplayMode')}
            >
              <Select
                value={preferences?.quotaDisplayMode ?? 'used'}
                disabled={disabled}
                onValueChange={(value) =>
                  void savePreference(
                    'quotaDisplayMode',
                    value as NativePreferences['quotaDisplayMode'],
                  )
                }
              >
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="used">
                    {t('settings.native.options.quotaUsed')}
                  </SelectItem>
                  <SelectItem value="remaining">
                    {t('settings.native.options.quotaRemaining')}
                  </SelectItem>
                </SelectContent>
              </Select>
            </PreferenceField>

            <PreferenceField
              hint={t('settings.native.hints.quotaDisplayStyle')}
              label={t('settings.native.fields.quotaDisplayStyle')}
            >
              <Select
                value={preferences?.quotaDisplayStyle ?? 'card'}
                disabled={disabled}
                onValueChange={(value) =>
                  void savePreference(
                    'quotaDisplayStyle',
                    value as NativePreferences['quotaDisplayStyle'],
                  )
                }
              >
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="card">
                    {t('settings.native.options.quotaStyleCard')}
                  </SelectItem>
                  <SelectItem value="lowestBar">
                    {t('settings.native.options.quotaStyleLowestBar')}
                  </SelectItem>
                  <SelectItem value="ring">
                    {t('settings.native.options.quotaStyleRing')}
                  </SelectItem>
                </SelectContent>
              </Select>
            </PreferenceField>

            <PreferenceField
              hint={t('settings.native.hints.resetTimeDisplayMode')}
              label={t('settings.native.fields.resetTimeDisplayMode')}
            >
              <Select
                value={preferences?.resetTimeDisplayMode ?? 'relative'}
                disabled={disabled}
                onValueChange={(value) =>
                  void savePreference(
                    'resetTimeDisplayMode',
                    value as NativePreferences['resetTimeDisplayMode'],
                  )
                }
              >
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="relative">
                    {t('settings.native.options.relative')}
                  </SelectItem>
                  <SelectItem value="absolute">
                    {t('settings.native.options.absolute')}
                  </SelectItem>
                </SelectContent>
              </Select>
            </PreferenceField>

            <PreferenceField
              hint={t('settings.native.hints.refreshCadence')}
              label={t('settings.native.fields.refreshCadence')}
            >
              <Select
                value={preferences?.refreshCadence ?? '10min'}
                disabled={disabled}
                onValueChange={(value) =>
                  void savePreference(
                    'refreshCadence',
                    value as NativePreferences['refreshCadence'],
                  )
                }
              >
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="manual">
                    {t('settings.native.options.manual')}
                  </SelectItem>
                  <SelectItem value="1min">1 min</SelectItem>
                  <SelectItem value="2min">2 min</SelectItem>
                  <SelectItem value="5min">5 min</SelectItem>
                  <SelectItem value="10min">10 min</SelectItem>
                  <SelectItem value="15min">15 min</SelectItem>
                </SelectContent>
              </Select>
            </PreferenceField>
          </PreferenceGroup>
        ) : null}

        {isMacHost ? (
          <PreferenceGroup
            description={t('settings.native.groups.menuBar.description')}
            title={t('settings.native.groups.menuBar.title')}
          >
            <SwitchField
              checked={preferences?.showInDock ?? true}
              disabled={disabled}
              label={t('settings.native.fields.showInDock')}
              onCheckedChange={(checked) =>
                void savePreference('showInDock', checked)
              }
            />
            <SwitchField
              checked={preferences?.showMenuBarIcon ?? true}
              disabled={disabled}
              label={t('settings.native.fields.showMenuBarIcon')}
              onCheckedChange={(checked) =>
                void savePreference('showMenuBarIcon', checked)
              }
            />
            <SwitchField
              checked={preferences?.showQuotaInMenuBar ?? true}
              disabled={disabled || !preferences?.showMenuBarIcon}
              label={t('settings.native.fields.showQuotaInMenuBar')}
              onCheckedChange={(checked) =>
                void savePreference('showQuotaInMenuBar', checked)
              }
            />
            <PreferenceField
              hint={t('settings.native.hints.menuBarMaxItems')}
              label={t('settings.native.fields.menuBarMaxItems')}
            >
              <Input
                type="number"
                min={1}
                max={10}
                value={preferences?.menuBarMaxItems ?? 3}
                disabled={
                  disabled ||
                  !preferences?.showMenuBarIcon ||
                  !preferences?.showQuotaInMenuBar
                }
                onChange={(event) =>
                  void savePreference(
                    'menuBarMaxItems',
                    Number(event.target.value),
                  )
                }
              />
            </PreferenceField>
            <PreferenceField
              hint={t('settings.native.hints.menuBarColorMode')}
              label={t('settings.native.fields.menuBarColorMode')}
            >
              <Select
                value={preferences?.menuBarColorMode ?? 'colored'}
                disabled={
                  disabled ||
                  !preferences?.showMenuBarIcon ||
                  !preferences?.showQuotaInMenuBar
                }
                onValueChange={(value) =>
                  void savePreference(
                    'menuBarColorMode',
                    value as NativePreferences['menuBarColorMode'],
                  )
                }
              >
                <SelectTrigger className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="colored">
                    {t('settings.native.options.colored')}
                  </SelectItem>
                  <SelectItem value="monochrome">
                    {t('settings.native.options.monochrome')}
                  </SelectItem>
                </SelectContent>
              </Select>
            </PreferenceField>
          </PreferenceGroup>
        ) : null}

        <PreferenceGroup
          description={t('settings.native.groups.privacyUsage.description')}
          title={t('settings.native.groups.privacyUsage.title')}
        >
          <SwitchField
            checked={preferences?.hideSensitiveInfo ?? false}
            disabled={disabled}
            label={t('settings.native.fields.hideSensitiveInfo')}
            onCheckedChange={(checked) =>
              void savePreference('hideSensitiveInfo', checked)
            }
          />
          <PreferenceField
            hint={t('settings.native.hints.totalUsageMode')}
            label={t('settings.native.fields.totalUsageMode')}
          >
            <Select
              value={preferences?.totalUsageMode ?? 'sessionOnly'}
              disabled={disabled}
              onValueChange={(value) =>
                void savePreference(
                  'totalUsageMode',
                  value as NativePreferences['totalUsageMode'],
                )
              }
            >
              <SelectTrigger className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="sessionOnly">
                  {t('settings.native.options.sessionOnly')}
                </SelectItem>
                <SelectItem value="combined">
                  {t('settings.native.options.combined')}
                </SelectItem>
              </SelectContent>
            </Select>
          </PreferenceField>
          <PreferenceField
            hint={t('settings.native.hints.modelAggregationMode')}
            label={t('settings.native.fields.modelAggregationMode')}
          >
            <Select
              value={preferences?.modelAggregationMode ?? 'lowest'}
              disabled={disabled}
              onValueChange={(value) =>
                void savePreference(
                  'modelAggregationMode',
                  value as NativePreferences['modelAggregationMode'],
                )
              }
            >
              <SelectTrigger className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="lowest">
                  {t('settings.native.options.lowest')}
                </SelectItem>
                <SelectItem value="average">
                  {t('settings.native.options.average')}
                </SelectItem>
              </SelectContent>
            </Select>
          </PreferenceField>
        </PreferenceGroup>

        <PreferenceGroup
          description={t('settings.native.groups.updates.description')}
          title={t('settings.native.groups.updates.title')}
        >
          <PreferenceStat
            label={t('settings.native.fields.updateSupport')}
            value={
              preferences?.updatesSupported
                ? t('about.status.enabled')
                : t('settings.native.values.velopackRequired')
            }
          />
          <PreferenceStat
            label={t('settings.native.fields.lastUpdateCheck')}
            value={formatUpdateCheckDate(
              preferences?.lastUpdateCheckAt,
              i18n.language,
              t('settings.native.values.never'),
            )}
          />
          <SwitchField
            checked={preferences?.autoCheckUpdates ?? true}
            disabled={disabled || !preferences?.updatesSupported}
            label={t('settings.native.fields.autoCheckUpdates')}
            onCheckedChange={(checked) =>
              void savePreference('autoCheckUpdates', checked)
            }
          />
          <PreferenceField
            hint={t('settings.native.hints.updateChannel')}
            label={t('settings.native.fields.updateChannel')}
          >
            <Select
              value={preferences?.updateChannel ?? 'stable'}
              disabled={
                disabled ||
                !preferences?.updatesSupported ||
                preferences?.updateChannelLocked
              }
              onValueChange={(value) =>
                void savePreference(
                  'updateChannel',
                  value as NativePreferences['updateChannel'],
                )
              }
            >
              <SelectTrigger className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="stable">
                  {t('settings.native.options.stable')}
                </SelectItem>
                <SelectItem value="beta">
                  {t('settings.native.options.beta')}
                </SelectItem>
              </SelectContent>
            </Select>
          </PreferenceField>
          <Button
            className="w-fit"
            type="button"
            variant="outline"
            disabled={
              disabled ||
              !preferences?.updatesSupported ||
              !preferences?.canCheckForUpdates ||
              state.checkingUpdates
            }
            onClick={() => void checkForUpdates()}
          >
            {state.checkingUpdates || preferences?.isCheckingForUpdates
              ? t('settings.native.actions.checkingUpdates')
              : t('settings.native.actions.checkForUpdates')}
          </Button>
        </PreferenceGroup>
      </div>

      {state.error ? (
        <p className="mt-3 text-danger text-sm">{state.error}</p>
      ) : null}
    </Panel>
  );
}

function formatUpdateCheckDate(
  value: string | null | undefined,
  locale: string,
  fallback: string,
) {
  if (!value) {
    return fallback;
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return fallback;
  }

  return new Intl.DateTimeFormat(locale, {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date);
}

function AdvancedProxySettingsPanel() {
  const { t } = useTranslation();
  const toast = useToast();
  const query = useAdvancedProxySettingsQuery();
  const mutation = useAdvancedProxySettingsMutation();
  const [proxyUrlDraft, setProxyUrlDraft] = useState('');
  const [requestRetryDraft, setRequestRetryDraft] = useState('');
  const [maxRetryIntervalDraft, setMaxRetryIntervalDraft] = useState('');
  const [localError, setLocalError] = useState<string | null>(null);

  const settings = query.data;
  const disabled = query.isLoading || mutation.isPending || !settings;

  useEffect(() => {
    setProxyUrlDraft(settings?.proxyUrl ?? '');
    setRequestRetryDraft(
      settings ? String(settings.requestRetry) : String(requestRetryRange.min),
    );
    setMaxRetryIntervalDraft(
      settings
        ? String(settings.maxRetryInterval)
        : String(maxRetryIntervalRange.min),
    );
  }, [settings]);

  const saveSetting = async <Key extends keyof AdvancedProxySettings>(
    key: Key,
    value: AdvancedProxySettings[Key],
  ) => {
    setLocalError(null);
    try {
      await mutation.mutateAsync({ key, value });
      toast.success(t('settings.advancedProxy.messages.saved'));
    } catch (error) {
      setLocalError(
        error instanceof Error ? error.message : t('common.unknownError'),
      );
    }
  };

  const saveProxyUrl = async () => {
    const proxyUrl = sanitizeProxyUrl(proxyUrlDraft);
    if (!validateProxyUrl(proxyUrl)) {
      setLocalError(t('settings.advancedProxy.errors.proxyUrlInvalid'));
      return;
    }

    await saveSetting('proxyUrl', proxyUrl);
  };

  const saveRequestRetry = async () => {
    const requestRetry = Number(requestRetryDraft);
    if (
      !Number.isInteger(requestRetry) ||
      requestRetry < requestRetryRange.min ||
      requestRetry > requestRetryRange.max
    ) {
      setLocalError(t('settings.advancedProxy.errors.requestRetryInvalid'));
      return;
    }

    await saveSetting('requestRetry', requestRetry);
  };

  const saveMaxRetryInterval = async () => {
    const maxRetryInterval = Number(maxRetryIntervalDraft);
    if (
      !Number.isInteger(maxRetryInterval) ||
      maxRetryInterval < maxRetryIntervalRange.min ||
      maxRetryInterval > maxRetryIntervalRange.max ||
      maxRetryInterval % maxRetryIntervalRange.step !== 0
    ) {
      setLocalError(t('settings.advancedProxy.errors.maxRetryIntervalInvalid'));
      return;
    }

    await saveSetting('maxRetryInterval', maxRetryInterval);
  };

  return (
    <Panel>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h2 className="font-medium text-foreground text-sm">
            {t('settings.advancedProxy.title')}
          </h2>
          <p className="mt-1 max-w-2xl text-muted-foreground text-sm">
            {t('settings.advancedProxy.description')}
          </p>
        </div>
        <StatusBadge tone={query.isError ? 'danger' : 'success'}>
          {query.isLoading
            ? t('settings.advancedProxy.status.loading')
            : query.isError
              ? t('settings.advancedProxy.status.unavailable')
              : t('settings.advancedProxy.status.ready')}
        </StatusBadge>
      </div>

      {query.isError ? (
        <p className="mt-3 text-danger text-sm">
          {query.error instanceof Error
            ? query.error.message
            : t('common.unknownError')}
        </p>
      ) : null}

      <div className="mt-6 grid gap-5 xl:grid-cols-2">
        <PreferenceGroup
          description={t('settings.advancedProxy.groups.upstream.description')}
          title={t('settings.advancedProxy.groups.upstream.title')}
        >
          <PreferenceField
            hint={t('settings.advancedProxy.hints.proxyUrl')}
            label={t('settings.advancedProxy.fields.proxyUrl')}
          >
            <div className="flex flex-col gap-2 sm:flex-row">
              <Input
                value={proxyUrlDraft}
                inputMode="url"
                autoComplete="off"
                disabled={disabled}
                placeholder="socks5://127.0.0.1:1080"
                onChange={(event) => {
                  setProxyUrlDraft(event.target.value);
                  setLocalError(null);
                }}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') {
                    void saveProxyUrl();
                  }
                }}
              />
              <div className="flex gap-2">
                <Button
                  type="button"
                  disabled={disabled}
                  onClick={() => void saveProxyUrl()}
                >
                  {t('common.save')}
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  disabled={disabled || !proxyUrlDraft}
                  onClick={() => {
                    setProxyUrlDraft('');
                    void saveSetting('proxyUrl', '');
                  }}
                >
                  {t('settings.native.actions.reset')}
                </Button>
              </div>
            </div>
          </PreferenceField>

          <p className="text-muted-foreground text-xs">
            {t('settings.advancedProxy.hints.proxyUrlSensitive')}
          </p>

          <PreferenceField
            hint={t('settings.advancedProxy.hints.routingStrategy')}
            label={t('settings.advancedProxy.fields.routingStrategy')}
          >
            <Select
              value={settings?.routingStrategy ?? 'round-robin'}
              disabled={disabled}
              onValueChange={(value) =>
                void saveSetting('routingStrategy', value as RoutingStrategy)
              }
            >
              <SelectTrigger className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="round-robin">
                  {t('settings.advancedProxy.options.roundRobin')}
                </SelectItem>
                <SelectItem value="fill-first">
                  {t('settings.advancedProxy.options.fillFirst')}
                </SelectItem>
              </SelectContent>
            </Select>
          </PreferenceField>
        </PreferenceGroup>

        <PreferenceGroup
          description={t('settings.advancedProxy.groups.quota.description')}
          title={t('settings.advancedProxy.groups.quota.title')}
        >
          <SwitchField
            checked={settings?.switchProject ?? true}
            disabled={disabled}
            label={t('settings.advancedProxy.fields.switchProject')}
            onCheckedChange={(checked) =>
              void saveSetting('switchProject', checked)
            }
          />
          <SwitchField
            checked={settings?.switchPreviewModel ?? true}
            disabled={disabled}
            label={t('settings.advancedProxy.fields.switchPreviewModel')}
            onCheckedChange={(checked) =>
              void saveSetting('switchPreviewModel', checked)
            }
          />
        </PreferenceGroup>

        <PreferenceGroup
          description={t('settings.advancedProxy.groups.retry.description')}
          title={t('settings.advancedProxy.groups.retry.title')}
        >
          <PreferenceField
            hint={t('settings.advancedProxy.hints.requestRetry')}
            label={t('settings.advancedProxy.fields.requestRetry')}
          >
            <div className="flex gap-2">
              <Input
                type="number"
                min={requestRetryRange.min}
                max={requestRetryRange.max}
                value={requestRetryDraft}
                disabled={disabled}
                onChange={(event) => {
                  setRequestRetryDraft(event.target.value);
                  setLocalError(null);
                }}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') {
                    void saveRequestRetry();
                  }
                }}
              />
              <Button
                type="button"
                disabled={disabled}
                onClick={() => void saveRequestRetry()}
              >
                {t('common.save')}
              </Button>
            </div>
          </PreferenceField>

          <PreferenceField
            hint={t('settings.advancedProxy.hints.maxRetryInterval')}
            label={t('settings.advancedProxy.fields.maxRetryInterval')}
          >
            <div className="flex gap-2">
              <Input
                type="number"
                min={maxRetryIntervalRange.min}
                max={maxRetryIntervalRange.max}
                step={maxRetryIntervalRange.step}
                value={maxRetryIntervalDraft}
                disabled={disabled}
                onChange={(event) => {
                  setMaxRetryIntervalDraft(event.target.value);
                  setLocalError(null);
                }}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') {
                    void saveMaxRetryInterval();
                  }
                }}
              />
              <Button
                type="button"
                disabled={disabled}
                onClick={() => void saveMaxRetryInterval()}
              >
                {t('common.save')}
              </Button>
            </div>
          </PreferenceField>
        </PreferenceGroup>

        <PreferenceGroup
          description={t('settings.advancedProxy.groups.logging.description')}
          title={t('settings.advancedProxy.groups.logging.title')}
        >
          <SwitchField
            checked={settings?.loggingToFile ?? true}
            disabled={disabled}
            label={t('settings.advancedProxy.fields.loggingToFile')}
            onCheckedChange={(checked) =>
              void saveSetting('loggingToFile', checked)
            }
          />
          <SwitchField
            checked={settings?.requestLog ?? false}
            disabled={disabled}
            label={t('settings.advancedProxy.fields.requestLog')}
            onCheckedChange={(checked) =>
              void saveSetting('requestLog', checked)
            }
          />
          <SwitchField
            checked={settings?.debugMode ?? false}
            disabled={disabled}
            label={t('settings.advancedProxy.fields.debugMode')}
            onCheckedChange={(checked) =>
              void saveSetting('debugMode', checked)
            }
          />
          <p className="text-danger text-xs">
            {t('settings.advancedProxy.hints.loggingSensitive')}
          </p>
        </PreferenceGroup>
      </div>

      {localError ? (
        <p className="mt-3 text-danger text-sm">{localError}</p>
      ) : null}
    </Panel>
  );
}

function PreferenceField({
  children,
  hint,
  label,
}: {
  children: ReactNode;
  hint: string;
  label: string;
}) {
  return (
    <div className="space-y-2">
      <Label>{label}</Label>
      {children}
      <p className="text-muted-foreground text-xs">{hint}</p>
    </div>
  );
}

function PreferenceGroup({
  children,
  description,
  title,
}: {
  children: ReactNode;
  description: string;
  title: string;
}) {
  return (
    <div className="rounded-lg border border-border p-4">
      <h3 className="font-medium text-foreground text-sm">{title}</h3>
      <p className="mt-1 text-muted-foreground text-xs">{description}</p>
      <div className="mt-4 space-y-4">{children}</div>
    </div>
  );
}

function proxyInstallStatusLabel(
  status: string | undefined,
  t: ReturnType<typeof useTranslation>['t'],
) {
  switch (status) {
    case 'dev-override':
      return t('settings.native.values.proxyInstallDevOverride');
    case 'bundled':
      return t('settings.native.values.proxyInstallBundled');
    case 'legacy-compatible':
      return t('settings.native.values.proxyInstallLegacyCompatible');
    case 'not-installed':
    case undefined:
    case '':
      return t('settings.native.values.notInstalled');
    default:
      return status;
  }
}

function PreferenceStat({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0 rounded-md border border-border px-3 py-2">
      <p className="text-muted-foreground text-xs">{label}</p>
      <p
        className="mt-1 truncate font-mono text-foreground text-xs"
        title={value}
      >
        {value || '-'}
      </p>
    </div>
  );
}

function SwitchField({
  checked,
  disabled,
  label,
  onCheckedChange,
}: {
  checked: boolean;
  disabled: boolean;
  label: string;
  onCheckedChange: (checked: boolean) => void;
}) {
  return (
    <div className="flex min-h-9 items-center justify-between gap-4 rounded-md border border-border px-3">
      <Label className="text-sm">{label}</Label>
      <Switch
        checked={checked}
        disabled={disabled}
        onCheckedChange={onCheckedChange}
      />
    </div>
  );
}

export function SettingsPage() {
  const { t } = useTranslation();
  const { bootstrap } = useAdminRuntime();

  return (
    <div className="space-y-6">
      <AdminPageHeader
        title={t('nav.settings')}
        description={t('settings.description')}
      />
      <NativePreferencesPanel />
      {bootstrap.capabilities.supportsManagementBridge ? (
        <AdvancedProxySettingsPanel />
      ) : null}
      <RemoteConnectionPanel />
    </div>
  );
}
