import { useQuery } from '@tanstack/react-query';
import type { HealthSnapshot, QuotaSnapshot } from '@/features/overview/types';
import type { LogsSummary } from '@/features/request-logs/types';
import { useAdminRuntime } from '@/lib/admin/runtime';

export function useOverviewQueries() {
  const { request } = useAdminRuntime();

  const pingQuery = useQuery({
    queryKey: ['overview', 'ping'],
    queryFn: async () => {
      await request<void>('/ping');
      return true;
    },
  });

  const healthQuery = useQuery({
    queryKey: ['overview', 'health'],
    queryFn: () => request<HealthSnapshot>('/health'),
  });

  const logsSummaryQuery = useQuery({
    queryKey: ['overview', 'logs-summary'],
    queryFn: () => request<LogsSummary>('/logs/summary'),
  });

  const quotaQuery = useQuery({
    queryKey: ['overview', 'quota'],
    queryFn: () => request<QuotaSnapshot>('/quota/summary'),
  });

  return {
    pingQuery,
    healthQuery,
    logsSummaryQuery,
    quotaQuery,
  };
}
