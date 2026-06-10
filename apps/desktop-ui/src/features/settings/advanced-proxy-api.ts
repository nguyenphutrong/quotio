import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAdminRuntime } from '@/lib/admin/runtime';

export const advancedProxySettingsQueryKey = ['settings', 'advanced-proxy'];

export type RoutingStrategy = 'round-robin' | 'fill-first';

export type AdvancedProxySettings = {
  proxyUrl: string;
  routingStrategy: RoutingStrategy;
  switchProject: boolean;
  switchPreviewModel: boolean;
  requestRetry: number;
  maxRetryInterval: number;
  loggingToFile: boolean;
  requestLog: boolean;
  debugMode: boolean;
};

export type AdvancedProxySettingsPatch = Partial<AdvancedProxySettings>;

type AdvancedProxyRequest = <T>(path: string, init?: RequestInit) => Promise<T>;

type QuotaExceededConfig = {
  'switch-project'?: boolean;
  'switch-preview-model'?: boolean;
  switchProject?: boolean;
  switchPreviewModel?: boolean;
};

type AdvancedProxyMutationVariables<Key extends keyof AdvancedProxySettings> = {
  key: Key;
  value: AdvancedProxySettings[Key];
};

type AdvancedProxyMutation = AdvancedProxyMutationVariables<
  keyof AdvancedProxySettings
>;

type ConfigResponse = {
  debug?: boolean;
  'proxy-url'?: string | null;
  proxyUrl?: string | null;
  'routing-strategy'?: RoutingStrategy;
  routingStrategy?: RoutingStrategy;
  'request-retry'?: number;
  requestRetry?: number;
  'max-retry-interval'?: number;
  maxRetryInterval?: number;
  'logging-to-file'?: boolean;
  loggingToFile?: boolean;
  'request-log'?: boolean;
  requestLog?: boolean;
  'quota-exceeded'?: QuotaExceededConfig;
  quotaExceeded?: QuotaExceededConfig;
};

type RoutingStrategyResponse = {
  strategy?: RoutingStrategy;
  value?: RoutingStrategy;
};

export const defaultAdvancedProxySettings: AdvancedProxySettings = {
  proxyUrl: '',
  routingStrategy: 'round-robin',
  switchProject: true,
  switchPreviewModel: true,
  requestRetry: 3,
  maxRetryInterval: 30,
  loggingToFile: true,
  requestLog: false,
  debugMode: false,
};

export function normalizeAdvancedProxySettings(
  config: ConfigResponse,
  routingResponse?: RoutingStrategyResponse,
): AdvancedProxySettings {
  const quotaExceeded = config['quota-exceeded'] ?? config.quotaExceeded;
  const routingStrategy =
    routingResponse?.strategy ??
    routingResponse?.value ??
    config['routing-strategy'] ??
    config.routingStrategy ??
    defaultAdvancedProxySettings.routingStrategy;

  return {
    proxyUrl: config['proxy-url'] ?? config.proxyUrl ?? '',
    routingStrategy,
    switchProject:
      quotaExceeded?.['switch-project'] ??
      quotaExceeded?.switchProject ??
      defaultAdvancedProxySettings.switchProject,
    switchPreviewModel:
      quotaExceeded?.['switch-preview-model'] ??
      quotaExceeded?.switchPreviewModel ??
      defaultAdvancedProxySettings.switchPreviewModel,
    requestRetry:
      config['request-retry'] ??
      config.requestRetry ??
      defaultAdvancedProxySettings.requestRetry,
    maxRetryInterval:
      config['max-retry-interval'] ??
      config.maxRetryInterval ??
      defaultAdvancedProxySettings.maxRetryInterval,
    loggingToFile:
      config['logging-to-file'] ??
      config.loggingToFile ??
      defaultAdvancedProxySettings.loggingToFile,
    requestLog:
      config['request-log'] ??
      config.requestLog ??
      defaultAdvancedProxySettings.requestLog,
    debugMode: config.debug ?? defaultAdvancedProxySettings.debugMode,
  };
}

export async function fetchAdvancedProxySettings(
  request: AdvancedProxyRequest,
) {
  const [config, routingResponse] = await Promise.all([
    request<ConfigResponse>('/config'),
    request<RoutingStrategyResponse>('/routing/strategy'),
  ]);

  return normalizeAdvancedProxySettings(config, routingResponse);
}

export async function updateAdvancedProxySetting<
  Key extends keyof AdvancedProxySettings,
>(request: AdvancedProxyRequest, key: Key, value: AdvancedProxySettings[Key]) {
  switch (key) {
    case 'proxyUrl': {
      const proxyUrl = String(value).trim();
      if (proxyUrl) {
        await request('/proxy-url', {
          method: 'PUT',
          body: JSON.stringify({ value: proxyUrl }),
        });
      } else {
        await request('/proxy-url', { method: 'DELETE' });
      }
      return;
    }
    case 'routingStrategy':
      await request('/routing/strategy', {
        method: 'PUT',
        body: JSON.stringify({ value }),
      });
      return;
    case 'switchProject':
      await request('/quota-exceeded/switch-project', {
        method: 'PATCH',
        body: JSON.stringify({ value }),
      });
      return;
    case 'switchPreviewModel':
      await request('/quota-exceeded/switch-preview-model', {
        method: 'PATCH',
        body: JSON.stringify({ value }),
      });
      return;
    case 'requestRetry':
      await request('/request-retry', {
        method: 'PUT',
        body: JSON.stringify({ value }),
      });
      return;
    case 'maxRetryInterval':
      await request('/max-retry-interval', {
        method: 'PUT',
        body: JSON.stringify({ value }),
      });
      return;
    case 'loggingToFile':
      await request('/logging-to-file', {
        method: 'PUT',
        body: JSON.stringify({ value }),
      });
      return;
    case 'requestLog':
      await request('/request-log', {
        method: 'PUT',
        body: JSON.stringify({ value }),
      });
      return;
    case 'debugMode':
      await request('/debug', {
        method: 'PUT',
        body: JSON.stringify({ value }),
      });
      return;
  }
}

export function sanitizeProxyUrl(value: string) {
  return value.trim();
}

export function validateProxyUrl(value: string) {
  const proxyUrl = sanitizeProxyUrl(value);
  if (!proxyUrl) {
    return true;
  }

  try {
    const parsed = new URL(proxyUrl);
    return ['http:', 'https:', 'socks5:', 'socks5h:'].includes(parsed.protocol);
  } catch {
    return false;
  }
}

export function useAdvancedProxySettingsQuery(enabled = true) {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: advancedProxySettingsQueryKey,
    queryFn: () => fetchAdvancedProxySettings(request),
    enabled,
  });
}

export function useAdvancedProxySettingsMutation() {
  const { request } = useAdminRuntime();
  const queryClient = useQueryClient();

  return useMutation<AdvancedProxyMutation, Error, AdvancedProxyMutation>({
    mutationFn: async ({ key, value }: AdvancedProxyMutation) => {
      await updateAdvancedProxySetting(request, key, value);
      return { key, value };
    },
    onSuccess: async ({ key, value }) => {
      queryClient.setQueryData<AdvancedProxySettings>(
        advancedProxySettingsQueryKey,
        (current) =>
          current
            ? {
                ...current,
                [key]: value,
              }
            : current,
      );
      await queryClient.invalidateQueries({
        queryKey: advancedProxySettingsQueryKey,
      });
    },
  });
}
