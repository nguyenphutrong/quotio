export type RawVirtualModelEntry = {
  id?: string;
  ID?: string;
  target?: string;
  Target?: string;
  priority?: number;
  Priority?: number;
  disabled?: boolean;
  Disabled?: boolean;
};

export type VirtualModelEntry = {
  id: string;
  target: string;
  priority: number;
  disabled: boolean;
  hasStableId: boolean;
};

export type RawVirtualModelRow = {
  id?: string;
  name?: string;
  disabled?: boolean;
  tier?: string;
  cost_hint?: string;
  entries?: RawVirtualModelEntry[] | null;
};

export type VirtualModelRow = {
  id: string;
  name: string;
  disabled: boolean;
  tier?: string;
  cost_hint?: string;
  entries: VirtualModelEntry[];
};

export type VirtualModelsStateResponse = {
  enabled: boolean;
  virtual_models: Record<
    string,
    {
      disabled?: boolean;
      tier?: string;
      cost_hint?: string;
      entries?: VirtualModelEntry[];
    }
  >;
  combo_templates: Record<string, unknown>;
};

export type VirtualModelsListResponse = {
  models: RawVirtualModelRow[];
};

export type VirtualModelPayloadEntry = {
  id: string;
  target: string;
  priority: number;
  disabled?: boolean;
};

export type AvailableTarget = {
  kind: 'direct' | 'virtual';
  provider: string;
  modelId: string;
  target: string;
  label: string;
};

export type AvailableTargetsResponse = {
  models: AvailableTarget[];
};

export type VirtualModelExportPayload = {
  enabled: boolean;
  virtual_models: Record<
    string,
    {
      disabled?: boolean;
      tier?: string;
      cost_hint?: string;
      entries?: VirtualModelPayloadEntry[];
    }
  >;
  combo_templates: Record<string, unknown>;
};

export type RawVirtualModelExportPayload = {
  enabled?: boolean;
  virtual_models?: Record<
    string,
    {
      disabled?: boolean;
      tier?: string;
      cost_hint?: string;
      entries?: RawVirtualModelEntry[] | null;
    }
  >;
  combo_templates?: Record<string, unknown>;
};

export type SuccessResponse = {
  success: boolean;
};
