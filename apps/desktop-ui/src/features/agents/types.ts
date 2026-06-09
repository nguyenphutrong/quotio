export type AgentItem = {
  id: string;
  label?: string;
  aliases?: string[];
  binaries?: string[];
  config_mode?: string;
  platform_support?: string;
  platformSupport?: string;
  support_message?: string;
  message?: string;
  rollback_available?: boolean;
  rollbackAvailable?: boolean;
  target_paths?: string[];
  docs_url?: string;
  capabilities?: string[];
  caveats?: string[];
};

export type AgentsResponse = {
  agents?: AgentItem[];
};

export type AgentGuideResponse = {
  guide: {
    tool: string;
    label?: string;
    config_mode?: string;
    docs_url?: string;
    target_paths?: string[];
    binaries?: string[];
    capabilities?: string[];
    steps?: string[];
    verify?: string[];
    config_snippet?: string;
    env_snippet?: string;
    caveats?: string[];
  };
};

export type AgentDiffResponse = {
  status: {
    tool: string;
    home_dir?: string;
    backup_dir?: string;
    base_url?: string;
    target_paths?: string[];
    installed: boolean;
    platform_support?: string;
    platformSupport?: string;
    latest_manifest?: string;
    rollback_available: boolean;
    rollbackAvailable?: boolean;
    message?: string;
  };
  plan: {
    tool: string;
    home_dir?: string;
    base_url?: string;
    backup_dir?: string;
    files?: Array<{
      target_path: string;
      existed: boolean;
      has_changes: boolean;
      before?: string;
      after?: string;
    }>;
  };
  summary: string;
};

export type AgentInstallResponse = {
  status: AgentDiffResponse['status'];
  plan: {
    tool: string;
    home_dir?: string;
    base_url?: string;
    backup_dir?: string;
    auth_token?: string;
  };
  manifest: {
    tool: string;
    home_dir?: string;
    backup_dir?: string;
    manifest?: string;
    created_at?: string;
    base_url?: string;
    auth_token?: string;
  };
  summary: string;
};

export type AgentRollbackResponse = {
  status: AgentDiffResponse['status'];
  manifest: AgentInstallResponse['manifest'];
  summary: string;
};
