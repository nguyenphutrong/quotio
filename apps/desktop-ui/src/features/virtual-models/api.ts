import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAdminRuntime } from '@/lib/admin/runtime';
import type {
  AvailableTargetsResponse,
  RawVirtualModelEntry,
  RawVirtualModelExportPayload,
  RawVirtualModelRow,
  SuccessResponse,
  VirtualModelEntry,
  VirtualModelExportPayload,
  VirtualModelPayloadEntry,
  VirtualModelRow,
  VirtualModelsListResponse,
  VirtualModelsStateResponse,
} from './types';

const stateQueryKey = ['virtual-models', 'state'];
const targetsQueryKey = ['virtual-models', 'targets'];

function buildAvailableTargetsPath(modelId?: string | null) {
  if (!modelId) {
    return '/virtual-models/available-targets';
  }

  return `/virtual-models/available-targets?forModel=${encodeURIComponent(modelId)}`;
}

function normalizeString(value: unknown) {
  if (typeof value !== 'string') {
    return undefined;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function normalizeNumber(value: unknown) {
  return typeof value === 'number' && Number.isFinite(value)
    ? value
    : undefined;
}

function normalizeBoolean(value: unknown) {
  return typeof value === 'boolean' ? value : undefined;
}

function normalizeVirtualModelEntry(
  entry: RawVirtualModelEntry,
  index: number,
): VirtualModelEntry | null {
  const target = normalizeString(entry.target ?? entry.Target);
  if (!target) {
    return null;
  }

  const priority =
    normalizeNumber(entry.priority ?? entry.Priority) ?? index + 1;
  const stableId = normalizeString(entry.id ?? entry.ID);

  return {
    id: stableId ?? `${target}#${priority}`,
    target,
    priority,
    disabled: normalizeBoolean(entry.disabled ?? entry.Disabled) ?? false,
    hasStableId: stableId !== undefined,
  };
}

function normalizeVirtualModel(
  model: RawVirtualModelRow,
): VirtualModelRow | null {
  const id = normalizeString(model.id) ?? normalizeString(model.name);
  const name = normalizeString(model.name) ?? normalizeString(model.id);
  if (!id || !name) {
    return null;
  }

  const rawEntries = Array.isArray(model.entries) ? model.entries : [];
  const entries = rawEntries
    .map((entry, index) => normalizeVirtualModelEntry(entry, index))
    .filter((entry): entry is VirtualModelEntry => entry !== null);

  return {
    id,
    name,
    disabled: normalizeBoolean(model.disabled) ?? false,
    tier: normalizeString(model.tier),
    cost_hint: normalizeString(model.cost_hint),
    entries,
  };
}

function normalizeVirtualModelExportPayload(
  payload: RawVirtualModelExportPayload,
): VirtualModelExportPayload {
  const virtualModels = Object.fromEntries(
    Object.entries(payload.virtual_models ?? {}).map(([name, model]) => {
      const rawEntries = Array.isArray(model.entries) ? model.entries : [];
      const entries = rawEntries
        .map((entry, index) => normalizeVirtualModelEntry(entry, index))
        .filter((entry): entry is VirtualModelEntry => entry !== null)
        .map(
          (entry): VirtualModelPayloadEntry => ({
            id: entry.id,
            target: entry.target,
            priority: entry.priority,
            disabled: entry.disabled || undefined,
          }),
        );

      return [
        name,
        {
          disabled: normalizeBoolean(model.disabled),
          tier: normalizeString(model.tier),
          cost_hint: normalizeString(model.cost_hint),
          entries,
        },
      ];
    }),
  );

  return {
    enabled: normalizeBoolean(payload.enabled) ?? false,
    virtual_models: virtualModels,
    combo_templates: payload.combo_templates ?? {},
  };
}

export function useVirtualModelsStateQuery() {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: stateQueryKey,
    queryFn: async () => {
      const [state, list] = await Promise.all([
        request<VirtualModelsStateResponse>('/virtual-models'),
        request<VirtualModelsListResponse>('/virtual-models/models'),
      ]);

      return {
        enabled: state.enabled,
        comboTemplates: state.combo_templates ?? {},
        models: (list.models ?? [])
          .map((model) => normalizeVirtualModel(model))
          .filter((model): model is VirtualModelRow => model !== null),
      };
    },
  });
}

export function useAvailableTargetsQuery(modelId: string | null) {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: [...targetsQueryKey, modelId],
    queryFn: () =>
      request<AvailableTargetsResponse>(buildAvailableTargetsPath(modelId)),
    enabled: modelId !== null,
  });
}

export function useModelInventoryTargetsQuery() {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: [...targetsQueryKey, 'inventory'],
    queryFn: () =>
      request<AvailableTargetsResponse>(buildAvailableTargetsPath()),
  });
}

export function useVirtualModelMutations() {
  const { request } = useAdminRuntime();
  const queryClient = useQueryClient();

  const invalidateState = async () => {
    await queryClient.invalidateQueries({ queryKey: stateQueryKey });
  };

  return {
    invalidateState,
    setEnabledMutation: useMutation({
      mutationFn: (enabled: boolean) =>
        request<SuccessResponse>('/virtual-models', {
          method: 'PATCH',
          body: JSON.stringify({ enabled }),
        }),
      onSuccess: invalidateState,
    }),
    createModelMutation: useMutation({
      mutationFn: (name: string) =>
        request<SuccessResponse>('/virtual-models/models', {
          method: 'POST',
          body: JSON.stringify({ name }),
        }),
      onSuccess: invalidateState,
    }),
    updateModelMutation: useMutation({
      mutationFn: ({
        modelId,
        payload,
      }: {
        modelId: string;
        payload: {
          name?: string;
          disabled?: boolean;
        };
      }) =>
        request<SuccessResponse>(`/virtual-models/models/${modelId}`, {
          method: 'PATCH',
          body: JSON.stringify(payload),
        }),
      onSuccess: invalidateState,
    }),
    deleteModelMutation: useMutation({
      mutationFn: (modelId: string) =>
        request<SuccessResponse>(`/virtual-models/models/${modelId}`, {
          method: 'DELETE',
        }),
      onSuccess: invalidateState,
    }),
    addEntryMutation: useMutation({
      mutationFn: ({
        modelId,
        targets,
      }: {
        modelId: string;
        targets: string[];
      }) =>
        request<SuccessResponse>(`/virtual-models/models/${modelId}/entries`, {
          method: 'POST',
          body: JSON.stringify({
            targets,
          }),
        }),
      onSuccess: invalidateState,
    }),
    deleteEntryMutation: useMutation({
      mutationFn: ({
        modelId,
        entryId,
      }: {
        modelId: string;
        entryId: string;
      }) =>
        request<SuccessResponse>(
          `/virtual-models/models/${modelId}/entries/${entryId}`,
          {
            method: 'DELETE',
          },
        ),
      onSuccess: invalidateState,
    }),
    reorderEntriesMutation: useMutation({
      mutationFn: ({
        modelId,
        entryIds,
      }: {
        modelId: string;
        entryIds: string[];
      }) =>
        request<SuccessResponse>(
          `/virtual-models/models/${modelId}/entries/reorder`,
          {
            method: 'POST',
            body: JSON.stringify({ entryIds }),
          },
        ),
      onSuccess: invalidateState,
    }),
    exportMutation: useMutation({
      mutationFn: () =>
        request<RawVirtualModelExportPayload>('/virtual-models/export').then(
          normalizeVirtualModelExportPayload,
        ),
    }),
    importMutation: useMutation({
      mutationFn: (payload: RawVirtualModelExportPayload) =>
        request<SuccessResponse>('/virtual-models/import', {
          method: 'POST',
          body: JSON.stringify(normalizeVirtualModelExportPayload(payload)),
        }),
      onSuccess: invalidateState,
    }),
  };
}
