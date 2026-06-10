import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAdminRuntime } from '@/lib/admin/runtime';
import type { LoggingSettings, LogsListResponse, LogsSummary } from './types';

const logsSummaryQueryKey = ['logs', 'summary'];
const logsListQueryKey = ['logs', 'list'] as const;
const loggingSettingsQueryKey = ['logs', 'settings'] as const;

type RequestLogResponse = {
  'request-log'?: boolean;
  requestLog?: boolean;
};

type LogsRequest = <T>(path: string, init?: RequestInit) => Promise<T>;

export const emptyLogsSummary: LogsSummary = {
  total_requests: 0,
  stream_requests: 0,
  prompt_tokens: 0,
  completion_tokens: 0,
  total_tokens: 0,
  estimated_cost_usd: 0,
  estimated_savings_usd: 0,
};

export const emptyLogsList: LogsListResponse = {
  entries: [],
  next_cursor: '',
  has_more: false,
};

export const defaultLoggingSettings: LoggingSettings = {
  capture_bodies: false,
};

export async function fetchLogsSummary(request: LogsRequest) {
  try {
    return await request<LogsSummary>('/logs/summary');
  } catch {
    return emptyLogsSummary;
  }
}

export async function fetchLogsList(
  request: LogsRequest,
  cursor: string,
  limit = 50,
  apiKeyID = '',
) {
  const normalizedAPIKeyID = apiKeyID.trim();
  const query = new URLSearchParams();
  query.set('limit', String(limit));
  if (cursor) {
    query.set('cursor', cursor);
  }
  if (normalizedAPIKeyID) {
    query.set('api_key_id', normalizedAPIKeyID);
  }

  try {
    return await request<LogsListResponse>(`/logs?${query.toString()}`);
  } catch {
    return emptyLogsList;
  }
}

export async function fetchLoggingSettings(request: LogsRequest) {
  try {
    const response = await request<RequestLogResponse>('/request-log');
    return {
      capture_bodies: Boolean(response['request-log'] ?? response.requestLog),
    };
  } catch {
    return defaultLoggingSettings;
  }
}

export async function updateLoggingSettings(
  request: LogsRequest,
  captureBodies: boolean,
) {
  await request('/request-log', {
    method: 'PATCH',
    body: JSON.stringify({ value: captureBodies }),
  });
  return { capture_bodies: captureBodies };
}

export function useLogsSummaryQuery() {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: logsSummaryQueryKey,
    queryFn: () => fetchLogsSummary(request),
    refetchInterval: 30_000,
  });
}

export function useLogsListQuery(cursor: string, limit = 50, apiKeyID = '') {
  const { request } = useAdminRuntime();
  const normalizedAPIKeyID = apiKeyID.trim();

  return useQuery({
    queryKey: [...logsListQueryKey, cursor, limit, normalizedAPIKeyID],
    queryFn: () => fetchLogsList(request, cursor, limit, normalizedAPIKeyID),
  });
}

export function useLoggingSettingsQuery() {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: loggingSettingsQueryKey,
    queryFn: () => fetchLoggingSettings(request),
  });
}

export function useLoggingSettingsMutation() {
  const { request } = useAdminRuntime();
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (captureBodies: boolean) =>
      updateLoggingSettings(request, captureBodies),
    onSuccess: async (data) => {
      queryClient.setQueryData(loggingSettingsQueryKey, data);
      await queryClient.invalidateQueries({ queryKey: logsListQueryKey });
    },
  });
}
