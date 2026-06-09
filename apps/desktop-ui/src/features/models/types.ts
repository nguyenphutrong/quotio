export type ModelCatalogItem = {
  id: string;
  model_id: string;
  object: string;
  created: number;
  owned_by: string;
  provider: string;
  tier?: string;
  context_window?: number;
  max_output_tokens?: number;
  available: boolean;
  capabilities?: Record<string, boolean>;
  capability_notes?: string[];
  live_discovered: boolean;
  metadata_source: string;
  warnings?: string[];
  fetched_at?: string;
  account_identity?: string;
  is_enabled: boolean;
  multiplier_label?: string;
  multiplier_value?: string;
  multiplier_plan?: 'free' | 'paid';
};

export type ModelCatalogProvider = {
  provider_id: string;
  provider_name: string;
  models: ModelCatalogItem[];
  plan_type?: string;
  plan_display_name?: string;
  plan_account_id?: string;
  plan_account_identity?: string;
};

export type ModelCatalogResponse = {
  providers: ModelCatalogProvider[];
};

export type EnabledModelsResponse = {
  provider_id: string;
  enabled_models: string[] | null;
  success?: boolean;
};

export type ProviderSyncSummary = {
  provider: string;
  checked_at: string;
  supported_models?: string[];
};

export type FilterCategory =
  | 'all'
  | 'reasoning'
  | 'vision'
  | 'websearch'
  | 'free'
  | 'embedding'
  | 'rerank'
  | 'function';

export type ModelRow = {
  rowId: string;
  providerId: string;
  providerName: string;
  item: ModelCatalogItem;
};
