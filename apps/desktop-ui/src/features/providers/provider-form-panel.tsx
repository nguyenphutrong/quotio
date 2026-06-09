import { Button } from '@quotio/ui/components/button';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@quotio/ui/components/dialog';
import { Input } from '@quotio/ui/components/input';
import { Label } from '@quotio/ui/components/label';
import { Switch } from '@quotio/ui/components/switch';
import { Textarea } from '@quotio/ui/components/textarea';
import { RiExternalLinkLine, RiLoader4Line } from '@remixicon/react';
import { useEffect, useState } from 'react';
import { CopyButton } from '@/components/admin/copy-button';
import { Panel } from '@/components/admin/panel';
import { ProviderIcon } from '@/components/admin/provider-icon';
import { StatusBadge } from '@/components/admin/status-badge';
import type {
  ProviderOAuthSession,
  ProviderOnboardingMode,
  ProviderPayload,
  ProviderResponse,
} from '@/features/providers/types';
import {
  getProviderDescription,
  getProviderDisplayName,
  normalizePayload,
  normalizeProviderId,
  providerCatalog,
} from '@/features/providers/types';
import { useAdminRuntime } from '@/lib/admin/runtime';

const opencodeGoWorkspaceIdHeader = 'x-quotio-opencode-go-workspace-id';
const opencodeGoAuthCookieHeader = 'x-quotio-opencode-go-auth-cookie';

function headersToText(headers?: Record<string, string>) {
  return headers ? JSON.stringify(headers, null, 2) : '{}';
}

function headerValue(headers: Record<string, string> | undefined, key: string) {
  return headers?.[key] ?? '';
}

function extractCookieEntries(input: unknown): Array<Record<string, unknown>> {
  if (Array.isArray(input)) {
    return input.filter(
      (item): item is Record<string, unknown> =>
        !!item && typeof item === 'object',
    );
  }
  if (input && typeof input === 'object') {
    const maybeCookies = (input as { cookies?: unknown }).cookies;
    if (Array.isArray(maybeCookies)) {
      return maybeCookies.filter(
        (item): item is Record<string, unknown> =>
          !!item && typeof item === 'object',
      );
    }
  }
  throw new Error('Cookie JSON must contain a cookies array');
}

function parseOpencodeGoCookieInput(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) {
    return '';
  }
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) {
    return trimmed;
  }

  const parsed = JSON.parse(trimmed) as unknown;
  const cookies = extractCookieEntries(parsed);
  const selectedCookies = cookies.filter((cookie) => {
    const domain = String(cookie.domain ?? '').toLowerCase();
    const name = String(cookie.name ?? '');
    return (
      (name === 'auth' || name === '__Host-auth' || name === 'oc_locale') &&
      (domain === 'opencode.ai' || domain.endsWith('.opencode.ai'))
    );
  });
  const hasAuthCookie = selectedCookies.some((cookie) => {
    const name = String(cookie.name ?? '');
    return name === 'auth' || name === '__Host-auth';
  });
  if (!hasAuthCookie) {
    throw new Error('Missing auth or __Host-auth cookie for opencode.ai');
  }
  return selectedCookies
    .map((cookie) => {
      const name = String(cookie.name ?? '').trim();
      const cookieValue = String(cookie.value ?? '').trim();
      return `${name}=${cookieValue}`;
    })
    .filter(Boolean)
    .join('; ');
}

function excludedModelsToText(excludedModels?: string[]) {
  return excludedModels?.join(', ') ?? '';
}

export function ProviderFormPanel({
  mode,
  provider: providerProp,
  onValidate,
  onCreate,
  onUpdate,
  onOAuthCreated,
  validationPreview,
  busy,
  hideHeader,
  initialProviderKey,
}: {
  mode: 'create' | 'edit';
  provider: ProviderResponse | null;
  onValidate: (payload: ProviderPayload) => Promise<void>;
  onCreate: (payload: ProviderPayload) => Promise<void>;
  onUpdate: (input: {
    id: string;
    label: string;
    disabled: boolean;
    headers?: Record<string, string>;
  }) => Promise<void>;
  onOAuthCreated?: (provider: ProviderResponse) => Promise<void> | void;
  validationPreview: ProviderResponse | null;
  busy: boolean;
  hideHeader?: boolean;
  initialProviderKey?: string;
}) {
  const { request, openExternal } = useAdminRuntime();
  const [step, setStep] = useState<1 | 2>(
    mode === 'create' && !initialProviderKey ? 1 : 2,
  );
  const [provider, setProvider] = useState(
    normalizeProviderId(providerProp?.provider ?? initialProviderKey ?? ''),
  );
  const [label, setLabel] = useState(providerProp?.label ?? '');
  const [secret, setSecret] = useState('');
  const [disabled, setDisabled] = useState(Boolean(providerProp?.disabled));
  const [authType, setAuthType] = useState(
    providerProp?.validation.auth_type ||
      (initialProviderKey
        ? providerCatalog[normalizeProviderId(initialProviderKey)]?.type
        : undefined) ||
      'api_key',
  );
  const [projectId, setProjectId] = useState(providerProp?.project_id ?? '');
  const [priority, setPriority] = useState(String(providerProp?.priority ?? 0));
  const [prefix, setPrefix] = useState(providerProp?.prefix ?? '');
  const [baseUrl, setBaseUrl] = useState(providerProp?.base_url ?? '');
  const [proxyUrl, setProxyUrl] = useState(providerProp?.proxy_url ?? '');
  const [excludedModels, setExcludedModels] = useState(
    excludedModelsToText(providerProp?.excluded_models),
  );
  const [headersText, setHeadersText] = useState(
    headersToText(providerProp?.headers),
  );
  const [opencodeGoWorkspaceId, setOpencodeGoWorkspaceId] = useState(
    headerValue(providerProp?.headers, opencodeGoWorkspaceIdHeader),
  );
  const [opencodeGoAuthCookie, setOpencodeGoAuthCookie] = useState(
    headerValue(providerProp?.headers, opencodeGoAuthCookieHeader),
  );
  const [cookieImportOpen, setCookieImportOpen] = useState(false);
  const [cookieImportText, setCookieImportText] = useState('');
  const [cookieImportError, setCookieImportError] = useState<string | null>(
    null,
  );
  const [localError, setLocalError] = useState<string | null>(null);

  const [oauthSession, setOAuthSession] = useState<ProviderOAuthSession | null>(
    null,
  );
  const [oauthStatus, setOAuthStatus] = useState<
    | 'idle'
    | 'starting'
    | 'awaiting_callback'
    | 'awaiting_device_confirmation'
    | 'completed'
    | 'failed'
    | 'expired'
  >('idle');
  const resetCreateForm = (nextProvider: string) => {
    const normalizedProvider = normalizeProviderId(nextProvider);
    setProvider(normalizedProvider);
    setLabel('');
    setSecret('');
    setDisabled(false);
    setAuthType(providerCatalog[normalizedProvider]?.type ?? 'api_key');
    setProjectId('');
    setPriority('0');
    setPrefix('');
    setBaseUrl('');
    setProxyUrl('');
    setExcludedModels('');
    setHeadersText('{}');
    setOpencodeGoWorkspaceId('');
    setOpencodeGoAuthCookie('');
    setCookieImportOpen(false);
    setCookieImportText('');
    setCookieImportError(null);
    setLocalError(null);
    setOAuthSession(null);
    setOAuthStatus('idle');
  };

  useEffect(() => {
    if (mode !== 'edit') {
      return;
    }

    setStep(2);
    setProvider(normalizeProviderId(providerProp?.provider ?? ''));
    setLabel(providerProp?.label ?? '');
    setDisabled(Boolean(providerProp?.disabled));
    setAuthType(providerProp?.validation.auth_type || 'api_key');
    setProjectId(providerProp?.project_id ?? '');
    setPriority(String(providerProp?.priority ?? 0));
    setPrefix(providerProp?.prefix ?? '');
    setBaseUrl(providerProp?.base_url ?? '');
    setProxyUrl(providerProp?.proxy_url ?? '');
    setExcludedModels(excludedModelsToText(providerProp?.excluded_models));
    setHeadersText(headersToText(providerProp?.headers));
    setOpencodeGoWorkspaceId(
      headerValue(providerProp?.headers, opencodeGoWorkspaceIdHeader),
    );
    setOpencodeGoAuthCookie(
      headerValue(providerProp?.headers, opencodeGoAuthCookieHeader),
    );
    setCookieImportOpen(false);
    setCookieImportText('');
    setCookieImportError(null);
    setSecret('');
    setLocalError(null);
    setOAuthSession(null);
    setOAuthStatus('idle');
  }, [providerProp, mode]);

  const payload = buildPayload();

  const onboardingMode: ProviderOnboardingMode =
    provider === 'custom'
      ? 'custom'
      : (providerCatalog[provider]?.onboarding ?? 'api_key');

  const handleProviderSelect = (key: string) => {
    resetCreateForm(key);
    setStep(2);
  };

  const isDeviceCode = onboardingMode === 'device_code';
  const isOAuth = onboardingMode === 'oauth';
  const isApiKey = onboardingMode === 'api_key';
  const isManual = onboardingMode === 'manual';
  const isCustom = onboardingMode === 'custom';
  const isBuiltInApiKeyCreate = mode === 'create' && isApiKey;
  const usesSessionFlow = isOAuth || isDeviceCode;
  const isOpencodeGoEdit = mode === 'edit' && provider === 'opencode-go';
  const showsOpencodeGoQuotaMetadata = provider === 'opencode-go';

  useEffect(() => {
    if (oauthSession?.user_code) {
      navigator.clipboard.writeText(oauthSession.user_code).catch(() => {});
    }
  }, [oauthSession?.user_code]);

  useEffect(() => {
    if (
      mode !== 'create' ||
      step !== 2 ||
      !usesSessionFlow ||
      oauthSession ||
      !provider
    ) {
      return;
    }

    let cancelled = false;

    void (async () => {
      try {
        setLocalError(null);
        setOAuthStatus('starting');
        const session = await request<ProviderOAuthSession>(
          '/providers/oauth/start',
          {
            method: 'POST',
            body: JSON.stringify({
              provider,
            }),
          },
        );
        if (cancelled) {
          return;
        }
        setOAuthSession(session);
        setOAuthStatus(session.status);

        if (session.auth_url) {
          await openExternal(session.auth_url);
        }
      } catch (error) {
        if (cancelled) {
          return;
        }
        setOAuthStatus('failed');
        setLocalError(
          error instanceof Error ? error.message : 'OAuth start failed',
        );
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [
    mode,
    oauthSession,
    openExternal,
    provider,
    request,
    step,
    usesSessionFlow,
  ]);

  useEffect(() => {
    if (!oauthSession?.session_id) {
      return;
    }
    if (
      oauthStatus === 'completed' ||
      oauthStatus === 'failed' ||
      oauthStatus === 'expired'
    ) {
      return;
    }

    const intervalMs = Math.max(oauthSession.interval_seconds ?? 2, 1) * 1000;
    let cancelled = false;
    const timeoutId = window.setTimeout(async () => {
      try {
        const nextSession = await request<ProviderOAuthSession>(
          `/providers/oauth/sessions/${oauthSession.session_id}`,
        );
        if (cancelled) {
          return;
        }
        setOAuthSession(nextSession);
        setOAuthStatus(nextSession.status);
        if (nextSession.status === 'completed' && nextSession.credential) {
          await onOAuthCreated?.(nextSession.credential);
        } else if (
          nextSession.status === 'failed' ||
          nextSession.status === 'expired'
        ) {
          setLocalError(
            nextSession.error ||
              (nextSession.status === 'expired'
                ? 'OAuth session expired'
                : 'OAuth session failed'),
          );
        }
      } catch (error) {
        if (cancelled) {
          return;
        }
        setOAuthStatus('failed');
        setLocalError(
          error instanceof Error
            ? error.message
            : 'OAuth status polling failed',
        );
      }
    }, intervalMs);

    return () => {
      cancelled = true;
      window.clearTimeout(timeoutId);
    };
  }, [oauthSession, oauthStatus, onOAuthCreated, request]);

  const oauthLink =
    oauthSession?.auth_url || oauthSession?.verification_uri || '';
  const oauthActionLabel = isDeviceCode ? 'Open Link' : 'Open OAuth Link';

  if (step === 1 && mode === 'create') {
    return (
      <div className="space-y-4">
        {!hideHeader && (
          <div>
            <h2 className="text-lg font-semibold text-foreground">
              Select Provider
            </h2>
            <p className="text-sm text-muted-foreground">
              Choose a provider to add to your inventory.
            </p>
          </div>
        )}
        <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-3">
          {Object.entries(providerCatalog).map(([key, info]) => (
            <button
              type="button"
              key={key}
              onClick={() => handleProviderSelect(key)}
              className={`flex flex-col items-center justify-center gap-3 rounded-lg border bg-card p-4 text-center transition-all hover:bg-muted/50 hover:border-foreground/20 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring ${
                provider === key ? 'border-primary bg-muted' : ''
              }`}
            >
              <div className="flex h-10 w-10 items-center justify-center rounded-md border bg-background shadow-sm">
                <ProviderIcon provider={key} className="h-6 w-6" />
              </div>
              <div>
                <div className="text-sm font-medium">{info.name}</div>
                <div className="text-[10px] text-muted-foreground uppercase tracking-wider mt-1">
                  {info.onboarding === 'device_code'
                    ? 'Device Code'
                    : info.onboarding === 'oauth'
                      ? 'OAuth'
                      : info.onboarding === 'manual'
                        ? 'Manual'
                        : 'API Key'}
                </div>
              </div>
            </button>
          ))}
          <button
            type="button"
            onClick={() => handleProviderSelect('custom')}
            className={`flex flex-col items-center justify-center gap-3 rounded-lg border bg-card p-4 text-center transition-all hover:bg-muted/50 hover:border-foreground/20 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring ${
              provider === 'custom' ? 'border-primary bg-muted' : ''
            }`}
          >
            <div className="flex h-10 w-10 items-center justify-center rounded-md border bg-background shadow-sm">
              <ProviderIcon provider="custom" className="h-6 w-6" />
            </div>
            <div>
              <div className="text-sm font-medium">Custom Provider</div>
              <div className="text-[10px] text-muted-foreground uppercase tracking-wider mt-1">
                API Key
              </div>
            </div>
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-5">
      {!hideHeader && (
        <div className="flex items-center justify-between gap-3">
          <div>
            <h2 className="text-lg font-semibold text-foreground">
              {mode === 'create' ? 'Configure Provider' : 'Edit provider'}
            </h2>
            <p className="text-sm text-muted-foreground">
              {mode === 'create'
                ? isManual
                  ? 'Configure the explicit runtime settings for this provider.'
                  : 'Authenticate or configure the provider settings.'
                : isOpencodeGoEdit
                  ? 'Update label, disabled state, and OpenCode Go quota metadata.'
                  : 'Existing providers only allow label and disabled state updates from this endpoint.'}
            </p>
          </div>
          {validationPreview?.validation.valid ? (
            <StatusBadge tone="success">validated</StatusBadge>
          ) : null}
        </div>
      )}

      {mode === 'create' && (
        <div className="flex items-center justify-between border-b pb-4">
          <div className="flex items-center gap-3">
            <div className="flex h-10 w-10 items-center justify-center rounded-md border bg-background shadow-sm">
              <ProviderIcon provider={provider} className="h-6 w-6" />
            </div>
            <div>
              <div className="text-sm font-semibold">
                {getProviderDisplayName(provider)}
              </div>
              <div className="text-xs text-muted-foreground">
                {getProviderDescription(provider, 'Custom Provider')}
              </div>
            </div>
          </div>
          <Button
            variant="ghost"
            size="sm"
            onClick={() => {
              resetCreateForm('');
              setStep(1);
            }}
            className="text-xs"
          >
            Change Provider
          </Button>
        </div>
      )}

      {/* DEVICE CODE UI */}
      {mode === 'create' && onboardingMode === 'device_code' && (
        <div className="space-y-4 rounded-lg border bg-muted/30 p-4">
          <h3 className="text-sm font-semibold text-foreground">
            Authenticate with Device Code
          </h3>
          <p className="text-sm text-muted-foreground">
            {`Sign in with the ${getProviderDisplayName(provider).toLowerCase()} device flow. Quotio will keep polling until the authorization completes or expires.`}
          </p>

          <div className="flex items-center gap-2">
            <div className="flex-1 font-mono text-center rounded-md bg-background border px-4 py-2 font-bold tracking-widest text-lg">
              {oauthSession?.user_code || 'Starting…'}
            </div>
            <CopyButton
              variant="outline"
              size="icon"
              className="shrink-0 h-11 w-11"
              disabled={!oauthSession?.user_code}
              value={oauthSession?.user_code || ''}
            />
          </div>

          <div className="flex items-center gap-2 pt-2">
            <Button
              variant="default"
              className="flex-1"
              disabled={!oauthLink}
              onClick={() => {
                if (oauthLink) {
                  void openExternal(oauthLink);
                }
              }}
            >
              <RiExternalLinkLine className="mr-2 h-4 w-4" />
              {oauthActionLabel}
            </Button>
            <CopyButton
              variant="outline"
              className="flex-1"
              disabled={!oauthLink}
              value={oauthLink}
            >
              Copy Link
            </CopyButton>
          </div>

          <div className="pt-4 border-t border-muted-foreground/10 text-sm text-muted-foreground">
            {oauthStatus === 'starting' ? (
              <div className="flex items-center gap-2">
                <RiLoader4Line className="h-4 w-4 animate-spin" />
                Requesting device code…
              </div>
            ) : oauthStatus === 'awaiting_device_confirmation' ? (
              'Complete the provider confirmation page, then return here while Quotio finishes the session.'
            ) : oauthStatus === 'completed' ? (
              'Authorization completed. The provider has been created.'
            ) : oauthStatus === 'expired' ? (
              'This device code expired. Choose the provider again to restart the flow.'
            ) : null}
          </div>
        </div>
      )}

      {/* OAUTH UI */}
      {mode === 'create' && onboardingMode === 'oauth' && (
        <div className="space-y-4 rounded-lg border bg-muted/30 p-4">
          <h3 className="text-sm font-semibold text-foreground">
            Authenticate with OAuth
          </h3>
          <p className="text-sm text-muted-foreground">
            {provider === 'kiro'
              ? 'Quotio opens Kiro sign-in and the backend completes the localhost callback automatically.'
              : 'Quotio opens the provider-specific authorization page automatically and waits for the callback to complete.'}
          </p>

          <div className="flex items-center gap-2 pt-2">
            <Button
              variant="default"
              className="flex-1"
              disabled={!oauthLink}
              onClick={() => {
                if (oauthLink) {
                  void openExternal(oauthLink);
                }
              }}
            >
              <RiExternalLinkLine className="mr-2 h-4 w-4" />
              {oauthActionLabel}
            </Button>
            <CopyButton
              variant="outline"
              className="flex-1"
              disabled={!oauthLink}
              value={oauthLink}
            >
              Copy Link
            </CopyButton>
          </div>

          <div className="pt-4 border-t border-muted-foreground/10 mt-2 text-sm text-muted-foreground">
            {oauthStatus === 'starting' ? (
              <div className="flex items-center gap-2">
                <RiLoader4Line className="h-4 w-4 animate-spin" />
                Preparing the OAuth session…
              </div>
            ) : oauthStatus === 'awaiting_callback' ? (
              'Finish signing in with the opened provider page. Quotio will create the provider after the callback returns.'
            ) : oauthStatus === 'completed' ? (
              'Authorization completed. The provider has been created.'
            ) : oauthStatus === 'expired' ? (
              'This OAuth session expired. Choose the provider again to restart the flow.'
            ) : null}
          </div>
        </div>
      )}

      {/* BUILT-IN API KEY CREATE */}
      {isBuiltInApiKeyCreate ? (
        <div className="space-y-4">
          <Field label="API Key">
            <Input
              type="password"
              value={secret}
              onChange={(event) => setSecret(event.target.value)}
              placeholder="Paste API key"
            />
          </Field>
          {showsOpencodeGoQuotaMetadata
            ? renderOpencodeGoQuotaMetadata()
            : null}
        </div>
      ) : null}

      {/* STANDARD FORM (CUSTOM CREATE OR EDIT MODE) */}
      {mode === 'edit' || isCustom || (mode === 'create' && isManual) ? (
        <>
          <div className="grid gap-4 md:grid-cols-2">
            {provider === 'custom' && mode === 'create' && (
              <Field label="Custom Provider Name">
                <Input
                  value={label}
                  onChange={(event) => {
                    setLabel(event.target.value);
                    setProvider(event.target.value);
                  }}
                  placeholder="e.g., my-internal-api"
                />
              </Field>
            )}
            <Field label="Label">
              <Input
                value={label}
                onChange={(event) => setLabel(event.target.value)}
                placeholder="Optional display name"
              />
            </Field>
            <Field label="Disabled">
              <div className="flex h-9 items-center">
                <Switch checked={disabled} onCheckedChange={setDisabled} />
              </div>
            </Field>
            {!isOpencodeGoEdit ? (
              <>
                <Field label="Project ID">
                  <Input
                    value={projectId}
                    onChange={(event) => setProjectId(event.target.value)}
                    disabled={mode === 'edit'}
                  />
                </Field>
                <Field label="Priority">
                  <Input
                    value={priority}
                    onChange={(event) => setPriority(event.target.value)}
                    disabled={mode === 'edit'}
                  />
                </Field>
                <Field label="Prefix">
                  <Input
                    value={prefix}
                    onChange={(event) => setPrefix(event.target.value)}
                    disabled={mode === 'edit'}
                  />
                </Field>
                <Field label="Base URL">
                  <Input
                    value={baseUrl}
                    onChange={(event) => setBaseUrl(event.target.value)}
                    disabled={mode === 'edit'}
                    placeholder={
                      providerCatalog[provider]?.baseURL ||
                      'https://api.example.com'
                    }
                  />
                </Field>
              </>
            ) : null}
          </div>

          {!isOpencodeGoEdit ? (
            <>
              <Field
                label={
                  mode === 'create'
                    ? 'Secret'
                    : 'Secret (leave blank to keep current)'
                }
              >
                <Input
                  type="password"
                  value={secret}
                  onChange={(event) => setSecret(event.target.value)}
                  disabled={mode === 'edit'}
                  placeholder={
                    mode === 'edit'
                      ? (providerProp?.secret ?? '')
                      : 'Paste API key or runtime secret'
                  }
                />
              </Field>

              <div className="grid gap-4 md:grid-cols-2">
                <Field label="Proxy URL">
                  <Input
                    value={proxyUrl}
                    onChange={(event) => setProxyUrl(event.target.value)}
                    disabled={mode === 'edit'}
                  />
                </Field>
                <Field label="Excluded models">
                  <Input
                    value={excludedModels}
                    onChange={(event) => setExcludedModels(event.target.value)}
                    disabled={mode === 'edit'}
                    placeholder="gpt-4.1, claude-3-5-sonnet"
                  />
                </Field>
              </div>
            </>
          ) : null}

          {showsOpencodeGoQuotaMetadata ? (
            renderOpencodeGoQuotaMetadata()
          ) : (
            <Field label="Headers JSON">
              <Textarea
                value={headersText}
                onChange={(event) => setHeadersText(event.target.value)}
                disabled={mode === 'edit'}
                className="min-h-28 font-mono text-xs"
              />
            </Field>
          )}
        </>
      ) : null}

      {localError ? (
        <p className="text-sm text-destructive">{localError}</p>
      ) : null}

      {validationPreview ? (
        <Panel className="space-y-2 bg-background/60 p-4">
          <div className="flex items-center gap-2">
            <StatusBadge
              tone={validationPreview.validation.valid ? 'success' : 'danger'}
            >
              {validationPreview.validation.valid ? 'valid' : 'invalid'}
            </StatusBadge>
            <p className="text-sm text-muted-foreground">
              {validationPreview.validation.auth_type || authType}
              {validationPreview.validation.account_identity
                ? ` · ${validationPreview.validation.account_identity}`
                : ''}
            </p>
          </div>
          {validationPreview.validation.error ? (
            <p className="text-sm text-destructive">
              {validationPreview.validation.error}
            </p>
          ) : null}
          {validationPreview.validation.warnings?.length ? (
            <ul className="list-disc space-y-1 pl-5 text-sm text-amber-700">
              {validationPreview.validation.warnings.map((warning) => (
                <li key={warning}>{warning}</li>
              ))}
            </ul>
          ) : null}
        </Panel>
      ) : null}

      <div className="flex flex-wrap gap-3">
        {mode === 'create' ? (
          !usesSessionFlow ? (
            <>
              <Button
                variant="outline"
                disabled={busy || !secret}
                onClick={() => void run(async () => onValidate(payload))}
              >
                Validate
              </Button>
              <Button
                disabled={busy || !secret}
                onClick={() => void run(async () => onCreate(payload))}
              >
                Add Provider
              </Button>
            </>
          ) : null
        ) : providerProp ? (
          <Button
            disabled={busy}
            onClick={() =>
              void run(async () =>
                onUpdate({
                  id: providerProp.id,
                  label,
                  disabled,
                  headers:
                    provider === 'opencode-go'
                      ? buildOpencodeGoHeaders()
                      : undefined,
                }),
              )
            }
          >
            Save changes
          </Button>
        ) : null}
      </div>

      <Dialog open={cookieImportOpen} onOpenChange={setCookieImportOpen}>
        <DialogContent className="sm:max-w-3xl">
          <DialogHeader>
            <DialogTitle>Import OpenCode Cookie JSON</DialogTitle>
            <DialogDescription>
              Paste exported cookie JSON for <code>opencode.ai</code>. Quotio
              will extract the auth cookie and store only the cookie header
              value needed for quota sync.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-3">
            <Textarea
              value={cookieImportText}
              onChange={(event) => setCookieImportText(event.target.value)}
              className="min-h-48 w-full max-w-full overflow-x-auto whitespace-pre-wrap break-all font-mono text-xs"
              placeholder='{"url":"https://opencode.ai","cookies":[...]}'
            />
            {cookieImportError ? (
              <p className="text-sm text-destructive">{cookieImportError}</p>
            ) : null}
          </div>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => setCookieImportOpen(false)}
            >
              Cancel
            </Button>
            <Button type="button" onClick={handleImportOpencodeGoCookieJson}>
              Import
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );

  async function run(action: () => Promise<void>) {
    try {
      setLocalError(null);
      await action();
    } catch (error) {
      setLocalError(
        error instanceof Error ? error.message : 'Provider action failed',
      );
    }
  }

  function buildPayload(): ProviderPayload {
    try {
      const parsedHeaders =
        provider === 'opencode-go'
          ? buildOpencodeGoHeaders()
          : (JSON.parse(headersText || '{}') as Record<string, string>);

      return normalizePayload({
        provider:
          provider === 'custom'
            ? label || 'custom'
            : normalizeProviderId(provider),
        label,
        disabled,
        secret,
        project_id: projectId,
        priority: Number(priority || 0),
        prefix,
        base_url: baseUrl,
        proxy_url: proxyUrl,
        excluded_models: excludedModels
          .split(',')
          .map((s) => s.trim())
          .filter(Boolean),
        headers: parsedHeaders,
        auth_type: authType,
      });
    } catch {
      setLocalError(
        provider === 'opencode-go'
          ? 'OpenCode Go cookie must be a raw auth cookie or valid exported cookie JSON'
          : 'Headers must be valid JSON',
      );
      return normalizePayload({
        provider:
          provider === 'custom'
            ? label || 'custom'
            : normalizeProviderId(provider),
        label,
        disabled,
        secret,
        auth_type: authType,
      });
    }
  }

  function buildOpencodeGoHeaders(): Record<string, string> | undefined {
    const headers: Record<string, string> = {};
    const workspaceId = opencodeGoWorkspaceId.trim();
    const authCookie = parseOpencodeGoCookieInput(opencodeGoAuthCookie);

    if (workspaceId) {
      headers[opencodeGoWorkspaceIdHeader] = workspaceId;
    }
    if (authCookie) {
      headers[opencodeGoAuthCookieHeader] = authCookie;
    }

    return Object.keys(headers).length > 0 ? headers : undefined;
  }

  function handleImportOpencodeGoCookieJson() {
    try {
      const parsed = parseOpencodeGoCookieInput(cookieImportText);
      setOpencodeGoAuthCookie(parsed);
      setCookieImportError(null);
      setCookieImportOpen(false);
      setCookieImportText('');
    } catch (error) {
      setCookieImportError(
        error instanceof Error
          ? error.message
          : 'Failed to parse exported cookie JSON',
      );
    }
  }

  function renderOpencodeGoQuotaMetadata() {
    return (
      <Field label="Quota Metadata">
        <div className="space-y-3">
          <div className="grid gap-3 md:grid-cols-2">
            <div className="space-y-2">
              <Label className="text-xs text-muted-foreground">
                {opencodeGoWorkspaceIdHeader}
              </Label>
              <Input
                value={opencodeGoWorkspaceId}
                onChange={(event) =>
                  setOpencodeGoWorkspaceId(event.target.value)
                }
                placeholder="wrk_..."
              />
            </div>
            <div className="space-y-2">
              <Label className="text-xs text-muted-foreground">
                {opencodeGoAuthCookieHeader}
              </Label>
              <div className="space-y-2">
                <Input
                  type="password"
                  value={opencodeGoAuthCookie}
                  onChange={(event) =>
                    setOpencodeGoAuthCookie(event.target.value)
                  }
                  className="font-mono text-xs"
                  placeholder="auth=..."
                />
                <div className="flex gap-2">
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() => {
                      setCookieImportText('');
                      setCookieImportError(null);
                      setCookieImportOpen(true);
                    }}
                  >
                    Import Cookie JSON
                  </Button>
                  {opencodeGoAuthCookie ? (
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      onClick={() => setOpencodeGoAuthCookie('')}
                    >
                      Clear
                    </Button>
                  ) : null}
                </div>
              </div>
            </div>
          </div>
          <p className="text-xs text-muted-foreground">
            Optional quota-only metadata for OpenCode Go. These values are
            stored into provider headers for quota sync only and do not affect
            inference requests. Paste a raw <code>auth=...</code> cookie, or use{' '}
            <code>Import Cookie JSON</code> to extract it from an exported{' '}
            <code>opencode.ai</code> cookie file.
          </p>
        </div>
      </Field>
    );
  }
}

function Field({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="space-y-2">
      <Label className="text-sm font-medium text-foreground">{label}</Label>
      {children}
    </div>
  );
}
