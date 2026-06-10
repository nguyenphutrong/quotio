import { useQuery } from '@tanstack/react-query';
import type { HealthSnapshot, QuotaSnapshot } from '@/features/overview/types';
import type { LogsSummary } from '@/features/request-logs/types';
import { useAdminRuntime } from '@/lib/admin/runtime';

type OverviewRequest = <T>(path: string, init?: RequestInit) => Promise<T>;

export const emptyHealthSnapshot: HealthSnapshot = {
  providers: {},
  affinity: {},
  concurrency: [],
  virtual_routes: [],
  provider_cooldowns: [],
  runtime: {},
};

export const emptyLogsSummary: LogsSummary = {
  total_requests: 0,
  stream_requests: 0,
  prompt_tokens: 0,
  completion_tokens: 0,
  total_tokens: 0,
  estimated_cost_usd: 0,
  estimated_savings_usd: 0,
};

export async function fetchOverviewPing(request: OverviewRequest) {
  await request<void>('/debug');
  return true;
}

export async function fetchOverviewHealth(request: OverviewRequest) {
  try {
    return await request<HealthSnapshot>('/health');
  } catch {
    return emptyHealthSnapshot;
  }
}

export async function fetchOverviewLogsSummary(request: OverviewRequest) {
  try {
    return await request<LogsSummary>('/logs/summary');
  } catch {
    return emptyLogsSummary;
  }
}

export function useOverviewQueries() {
  const { request } = useAdminRuntime();

  const pingQuery = useQuery({
    queryKey: ['overview', 'ping'],
    queryFn: () => fetchOverviewPing(request),
  });

  const healthQuery = useQuery({
    queryKey: ['overview', 'health'],
    queryFn: () => fetchOverviewHealth(request),
  });

  const logsSummaryQuery = useQuery({
    queryKey: ['overview', 'logs-summary'],
    queryFn: () => fetchOverviewLogsSummary(request),
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
