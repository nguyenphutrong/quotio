export type AmpModelMapping = {
  from: string;
  to: string;
  regex: boolean;
};

export type AmpCodeView = {
  upstream_url: string;
  effective_upstream_url: string;
  upstream_api_key: string;
  routing_mode: string;
  restrict_management_to_localhost: boolean;
  management_auth_policy: string;
  model_mappings: AmpModelMapping[];
};

export type AmpCodeResponse = {
  ampcode: AmpCodeView;
};

export type AmpRouteDecision = {
  route_type: string;
  requested_model?: string;
  resolved_model?: string;
  provider?: string;
  endpoint?: string;
  source?: string;
  fallback_reason?: string;
};

export type AmpSimulationResponse = {
  decision: AmpRouteDecision;
};

export type AmpCLISetupStatus = {
  tool: string;
  scope: string;
  scope_warning: string;
  home_dir: string;
  backup_dir: string;
  base_url: string;
  effective_upstream_url: string;
  target_paths: string[];
  installed: boolean;
  latest_manifest?: string;
  rollback_available: boolean;
  settings_path: string;
  secrets_path: string;
  settings_snippet: string;
  secrets_snippet: string;
  env_var_names: string[];
  env_snippet: string;
  amp_login_not_required: boolean;
  manual_setup_description: string;
  machine_scope_description: string;
  client_bearer_description: string;
  upstream_access_note: string;
};

export type AmpCLISetupStatusResponse = {
  cli_setup: AmpCLISetupStatus;
};

export type AmpCLISetupDiffResponse = {
  status: AmpCLISetupStatus;
  plan: {
    tool: string;
    home_dir: string;
    base_url: string;
    backup_dir: string;
    files: Array<{
      target_path: string;
      existed: boolean;
      has_changes: boolean;
      before?: string;
      after?: string;
    }>;
  };
  summary: string;
};

export type AmpCLISetupApplyResponse = {
  status: AmpCLISetupStatus;
  plan: AmpCLISetupDiffResponse['plan'];
  manifest: {
    tool: string;
    home_dir: string;
    backup_dir: string;
    manifest: string;
    created_at: string;
    base_url: string;
    auth_token: string;
    files: Array<{
      target_path: string;
      backup_path?: string;
      existed: boolean;
    }>;
    rolled_back?: boolean;
  };
  summary: string;
};

export type AmpCLISetupRollbackResponse = {
  status: AmpCLISetupStatus;
  manifest: AmpCLISetupApplyResponse['manifest'];
  summary: string;
};
