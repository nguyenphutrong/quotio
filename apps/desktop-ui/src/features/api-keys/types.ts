export type APIKeyUsageSummary = {
  request_count: number;
  token_input: number;
  token_output: number;
  total_tokens: number;
  estimated_cost_usd: number;
};

export type APIKeyRecord = {
  id: string;
  name: string;
  status: 'active' | 'disabled' | 'deleted';
  scope_type: string;
  origin: string;
  created_at: string;
  last_used_at?: string | null;
  last_four: string;
  masked_value: string;
  usage_summary_30d?: APIKeyUsageSummary;
};

export type APIKeysListResponse = {
  keys: APIKeyRecord[];
};

export type APIKeyCreateResponse = {
  key: APIKeyRecord;
  plaintext_key: string;
};

export type APIKeyMutationResponse = {
  key: APIKeyRecord;
};

export type APIKeyUsagePoint = {
  bucket_start: string;
  request_count: number;
  token_input: number;
  token_output: number;
  total_tokens: number;
  estimated_cost_usd: number;
};

export type APIKeyUsageBreakdown = {
  value: string;
  request_count: number;
  token_input: number;
  token_output: number;
  total_tokens: number;
  estimated_cost_usd: number;
};

export type APIKeyUsageResponse = {
  summary: APIKeyUsageSummary;
  series: APIKeyUsagePoint[];
  breakdowns: {
    models: APIKeyUsageBreakdown[];
    endpoints: APIKeyUsageBreakdown[];
  };
};
