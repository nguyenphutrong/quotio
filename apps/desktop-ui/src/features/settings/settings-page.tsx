import { Button } from '@quotio/ui/components/button';
import { Input } from '@quotio/ui/components/input';
import { Label } from '@quotio/ui/components/label';
import { useEffect, useId, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { AdminPageHeader } from '@/components/admin/admin-page-header';
import { Panel } from '@/components/admin/panel';
import { StatusBadge } from '@/components/admin/status-badge';
import { useToast } from '@/components/admin/toast-provider';
import { useAdminRuntime } from '@/lib/admin/runtime';

const MANAGEMENT_BASE_URL_TARGET = 'Quotio/ManagementBaseUrl';
const MANAGEMENT_KEY_TARGET = 'Quotio/ManagementKey';

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
      <Panel>
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
    <Panel>
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

export function SettingsPage() {
  const { t } = useTranslation();

  return (
    <div className="space-y-6">
      <AdminPageHeader
        title={t('nav.settings')}
        description={t('settings.description')}
      />
      <RemoteConnectionPanel />
    </div>
  );
}
