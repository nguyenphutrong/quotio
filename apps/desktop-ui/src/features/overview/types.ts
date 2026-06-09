export type QuotaProviderSummary = {
  provider: string;
  accounts: number;
  stale_count: number;
};

export type QuotaSnapshot = {
  providers: QuotaProviderSummary[];
};

export type HealthSnapshot = {
  providers: Record<string, unknown[]>;
  affinity: {
    bindings?: unknown[];
  };
  concurrency: unknown[];
  virtual_routes: unknown[];
  provider_cooldowns: unknown[];
  runtime: Record<string, Record<string, unknown>>;
};
