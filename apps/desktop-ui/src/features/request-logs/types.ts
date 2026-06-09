export type LogsSummary = {
  total_requests: number;
  stream_requests: number;
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
  estimated_cost_usd: number;
  estimated_savings_usd: number;
};

export type LogEntry = {
  timestamp: string;
  request_id: string;
  requested_model?: string;
  request_method?: string;
  api_key_id?: string;
  api_key_scope?: string;
  api_key_name_snapshot?: string;
  endpoint: string;
  provider: string;
  model: string;
  app?: string;
  stream: boolean;
  source: string;
  status_code: number;
  duration_ms: number;
  credential_key: string;
  finish_reason?: string;
  prompt_tokens: number;
  completion_tokens: number;
  total_tokens: number;
  cache_tokens?: number;
  estimated_cost_usd: number;
  estimated_savings_usd: number;
  request_body?: string;
  response_body?: string;
  error?: string;
};

export type LogsListResponse = {
  entries: LogEntry[];
  next_cursor: string;
  has_more: boolean;
};

export type LoggingSettings = {
  capture_bodies: boolean;
};
