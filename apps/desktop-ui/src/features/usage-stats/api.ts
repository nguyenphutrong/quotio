import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAdminRuntime } from '@/lib/admin/runtime';
import type {
  RawUsageStatsEvent,
  RawUsageStatsEventsResponse,
  UsageStatsEvent,
  UsageStatsEventsResponse,
  UsageStatsModelPricesSyncResult,
  UsageStatsStatus,
  UsageStatsSummaryResponse,
} from './types';

const statusQueryKey = ['usage-stats', 'status'] as const;
const summaryQueryKey = ['usage-stats', 'summary'] as const;
const eventsQueryKey = ['usage-stats', 'events'] as const;

export type UsageStatsFilters = {
  account: string;
  model: string;
  channel: string;
  authIndex: string;
  limit: number;
  offset: number;
};

function stringValue(event: RawUsageStatsEvent, ...keys: string[]) {
  for (const key of keys) {
    const value = event[key];
    if (typeof value === 'string' && value.trim()) {
      return value;
    }
  }
  return '';
}

function numberValue(event: RawUsageStatsEvent, ...keys: string[]) {
  for (const key of keys) {
    const value = event[key];
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value;
    }
  }
  return 0;
}

function optionalNumberValue(event: RawUsageStatsEvent, ...keys: string[]) {
  for (const key of keys) {
    const value = event[key];
    if (typeof value === 'number' && Number.isFinite(value)) {
      return value;
    }
  }
  return null;
}

function booleanValue(event: RawUsageStatsEvent, ...keys: string[]) {
  for (const key of keys) {
    const value = event[key];
    if (typeof value === 'boolean') {
      return value;
    }
  }
  return false;
}

function normalizeEvent(event: RawUsageStatsEvent): UsageStatsEvent {
  const id = String(numberValue(event, 'ID', 'id'));

  return {
    id,
    timestamp_ms: numberValue(event, 'TimestampMS', 'timestamp_ms'),
    provider: stringValue(event, 'Provider', 'provider'),
    channel: stringValue(event, 'Channel', 'channel'),
    model: stringValue(event, 'Model', 'model'),
    requested_model: stringValue(event, 'RequestedModel', 'requested_model'),
    resolved_model: stringValue(event, 'ResolvedModel', 'resolved_model'),
    endpoint: stringValue(event, 'Endpoint', 'endpoint'),
    method: stringValue(event, 'Method', 'method'),
    path: stringValue(event, 'Path', 'path'),
    account: stringValue(event, 'Account', 'account'),
    account_hash: stringValue(event, 'AccountHash', 'account_hash'),
    api_key_hash: stringValue(event, 'APIKeyHash', 'api_key_hash'),
    status_code: numberValue(event, 'StatusCode', 'status_code'),
    prompt_tokens: numberValue(event, 'PromptTokens', 'prompt_tokens'),
    completion_tokens: numberValue(
      event,
      'CompletionTokens',
      'completion_tokens',
    ),
    reasoning_tokens: numberValue(event, 'ReasoningTokens', 'reasoning_tokens'),
    cached_tokens: numberValue(event, 'CachedTokens', 'cached_tokens'),
    cache_tokens: numberValue(event, 'CacheTokens', 'cache_tokens'),
    total_tokens: numberValue(event, 'TotalTokens', 'total_tokens'),
    latency_ms: optionalNumberValue(event, 'LatencyMS', 'latency_ms'),
    failed: booleanValue(event, 'Failed', 'failed'),
    estimated_cost_usd: optionalNumberValue(
      event,
      'EstimatedCostUSD',
      'estimated_cost_usd',
    ),
  };
}

function buildUsageQuery(filters: UsageStatsFilters, includeCost = false) {
  const query = new URLSearchParams();
  if (filters.account.trim()) query.set('account', filters.account.trim());
  if (filters.model.trim()) query.set('model', filters.model.trim());
  if (filters.channel.trim()) query.set('channel', filters.channel.trim());
  if (filters.authIndex.trim()) {
    query.set('auth_index', filters.authIndex.trim());
  }
  query.set('limit', String(filters.limit));
  query.set('offset', String(filters.offset));
  if (includeCost) query.set('include_cost', 'true');
  return query.toString();
}

export function useUsageStatsStatusQuery() {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: statusQueryKey,
    queryFn: () => request<UsageStatsStatus>('/usage-stats/status'),
  });
}

export function useUsageStatsSummaryQuery(
  filters: UsageStatsFilters,
  enabled: boolean,
) {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: [...summaryQueryKey, filters],
    enabled,
    queryFn: () =>
      request<UsageStatsSummaryResponse>(
        `/usage-stats/summary?${buildUsageQuery(filters, true)}`,
      ).then((response) => response.summary),
  });
}

export function useUsageStatsEventsQuery(
  filters: UsageStatsFilters,
  enabled: boolean,
) {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: [...eventsQueryKey, filters],
    enabled,
    queryFn: () =>
      request<RawUsageStatsEventsResponse>(
        `/usage-stats/events?${buildUsageQuery(filters)}`,
      ).then(
        (response): UsageStatsEventsResponse => ({
          events: (response.events ?? []).map(normalizeEvent),
          limit: response.limit ?? filters.limit,
          offset: response.offset ?? filters.offset,
        }),
      ),
  });
}

export function useUsageStatsMutations() {
  const { request } = useAdminRuntime();
  const queryClient = useQueryClient();

  return {
    syncModelPricesMutation: useMutation({
      mutationFn: () =>
        request<UsageStatsModelPricesSyncResult>(
          '/usage-stats/model-prices/sync',
          {
            method: 'POST',
            body: JSON.stringify({ models: [], include_prices: false }),
          },
        ),
      onSuccess: async () => {
        await queryClient.invalidateQueries({ queryKey: statusQueryKey });
        await queryClient.invalidateQueries({ queryKey: summaryQueryKey });
      },
    }),
  };
}
