import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAdminRuntime } from '@/lib/admin/runtime';
import type { LoggingSettings, LogsListResponse, LogsSummary } from './types';

const logsSummaryQueryKey = ['logs', 'summary'];
const logsListQueryKey = ['logs', 'list'] as const;
const loggingSettingsQueryKey = ['logs', 'settings'] as const;

export function useLogsSummaryQuery() {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: logsSummaryQueryKey,
    queryFn: () => request<LogsSummary>('/logs/summary'),
    refetchInterval: 30_000,
  });
}

export function useLogsListQuery(cursor: string, limit = 50, apiKeyID = '') {
  const { request } = useAdminRuntime();
  const normalizedAPIKeyID = apiKeyID.trim();
  const query = new URLSearchParams();
  query.set('limit', String(limit));
  if (cursor) {
    query.set('cursor', cursor);
  }
  if (normalizedAPIKeyID) {
    query.set('api_key_id', normalizedAPIKeyID);
  }

  return useQuery({
    queryKey: [...logsListQueryKey, cursor, limit, normalizedAPIKeyID],
    queryFn: () => request<LogsListResponse>(`/logs?${query.toString()}`),
  });
}

export function useLoggingSettingsQuery() {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: loggingSettingsQueryKey,
    queryFn: () => request<LoggingSettings>('/logging'),
  });
}

export function useLoggingSettingsMutation() {
  const { request } = useAdminRuntime();
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (captureBodies: boolean) =>
      request<LoggingSettings>('/logging', {
        method: 'PATCH',
        body: JSON.stringify({ capture_bodies: captureBodies }),
      }),
    onSuccess: async (data) => {
      queryClient.setQueryData(loggingSettingsQueryKey, data);
      await queryClient.invalidateQueries({ queryKey: logsListQueryKey });
    },
  });
}
