export type UsageStatsStatus = {
  enabled: boolean;
  open: boolean;
  path?: string | null;
  model_prices_count?: number | null;
  model_prices_last_synced_at_ms?: number | null;
  model_prices_last_updated_at_ms?: number | null;
  model_prices_syncing?: boolean | null;
  model_prices_sync_error?: string | null;
};

export type UsageStatsTokens = {
  prompt_tokens: number;
  completion_tokens: number;
  reasoning_tokens: number;
  cached_tokens: number;
  cache_tokens: number;
  total_tokens: number;
};

export type UsageStatsSummary = {
  total_requests: number;
  success_count: number;
  failure_count: number;
  tokens: UsageStatsTokens;
  latency_sum_ms?: number | null;
  latency_count?: number | null;
  estimated_cost_usd?: number | null;
};

export type UsageStatsSummaryResponse = {
  summary: UsageStatsSummary;
};

export type RawUsageStatsEvent = Record<string, unknown>;

export type UsageStatsEvent = {
  id: string;
  timestamp_ms: number;
  provider: string;
  channel: string;
  model: string;
  requested_model: string;
  resolved_model: string;
  endpoint: string;
  method: string;
  path: string;
  account: string;
  account_hash: string;
  api_key_hash: string;
  status_code: number;
  prompt_tokens: number;
  completion_tokens: number;
  reasoning_tokens: number;
  cached_tokens: number;
  cache_tokens: number;
  total_tokens: number;
  latency_ms?: number | null;
  failed: boolean;
  estimated_cost_usd?: number | null;
};

export type UsageStatsEventsResponse = {
  events: UsageStatsEvent[];
  limit: number;
  offset: number;
};

export type RawUsageStatsEventsResponse = {
  events?: RawUsageStatsEvent[];
  limit?: number;
  offset?: number;
};

export type UsageStatsModelPricesSyncResult = {
  source: string;
  imported: number;
  skipped: number;
  unmatched?: string[] | null;
};
