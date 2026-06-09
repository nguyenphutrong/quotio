export type QuotaDisplayMode = 'used' | 'remaining';
export type QuotaDisplayStyle = 'overview' | 'focus';

export type QuotaModelView = {
  name: string;
  display_name: string;
  remaining_percent?: number;
  used_percent?: number;
  used?: number;
  limit?: number;
  remaining?: number;
  reset_time?: string;
  time_boundary_kind?: 'reset' | 'expires';
  quota_kind?: 'window' | 'absolute-credits' | 'replenishing-balance';
  display_unit?: 'percent' | 'usd' | 'credits' | 'tokens' | 'count';
  remaining_value?: number;
  limit_value?: number;
  replenish_rate_per_hour?: number;
  cap_value?: number;
  source?: string;
  source_description?: string;
};

export type QuotaAccountView = {
  credential_id: string;
  account_key: string;
  provider: string;
  quota_supported: boolean;
  quota_status: 'supported' | 'unsupported' | 'error';
  quota_status_reason?: string;
  plan_type?: string;
  plan_display_name?: string;
  is_forbidden: boolean;
  is_active: boolean;
  last_updated?: string;
  error?: string;
  models: QuotaModelView[];
  copilot_chat_models?: CopilotChatModelView[];
};

export type CopilotChatModelView = {
  model_id: string;
  display_name: string;
  multiplier_label?: string;
  multiplier_value?: string;
  multiplier_plan?: 'free' | 'paid';
  multiplier_applies: boolean;
};

export type QuotaProviderView = {
  provider: string;
  display_name: string;
  quota_supported: boolean;
  quota_status: 'supported' | 'unsupported' | 'error';
  quota_status_reason?: string;
  supports_refresh: boolean;
  supports_account_switch: boolean;
  accounts: QuotaAccountView[];
};

export type AccountSwitchingAccount = {
  id: string;
  email: string;
  is_active: boolean;
};

export type AccountSwitchingStatus = {
  provider: string;
  supported: boolean;
  accounts: AccountSwitchingAccount[];
};

export type QuotaView = {
  providers: QuotaProviderView[];
  account_switching: AccountSwitchingStatus;
};
