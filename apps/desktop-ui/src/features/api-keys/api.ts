import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAdminRuntime } from '@/lib/admin/runtime';
import type {
  APIKeyCreateResponse,
  APIKeyMutationResponse,
  APIKeysListResponse,
  APIKeyUsageResponse,
} from './types';

const clientKeysQueryKey = ['client-keys'] as const;
const clientKeyUsageQueryKey = ['client-key-usage'] as const;

type APIKeysRequest = <T>(path: string, init?: RequestInit) => Promise<T>;

const SUPPORTS_CPA_KEYS_ERROR =
  'unsupported endpoint: requires cpa++ api support';

function isCPAUnsupportedError(error: unknown): boolean {
  if (!(error instanceof Error)) {
    return false;
  }

  return error.message.toLowerCase().includes(SUPPORTS_CPA_KEYS_ERROR);
}

function withFallbackPath(path: string) {
  if (!path.startsWith('/client-keys')) {
    return path;
  }

  return path.replace(/^\/client-keys/, '/api-keys');
}

async function requestWithFallback<T>(
  request: APIKeysRequest,
  path: string,
  init?: RequestInit,
) {
  try {
    return await request<T>(path, init);
  } catch (error) {
    if (!isCPAUnsupportedError(error)) {
      throw error;
    }
    return request<T>(withFallbackPath(path), init);
  }
}

export type APIKeyListFilters = {
  status: string;
  q: string;
  sort: string;
  order: string;
};

export type APIKeyUsageFilters = {
  from: string;
  to: string;
  model: string;
  endpoint: string;
  granularity: 'hour' | 'day';
};

export function buildClientKeysPath(filters: APIKeyListFilters) {
  const params = new URLSearchParams();
  if (filters.status) params.set('status', filters.status);
  if (filters.q) params.set('q', filters.q);
  if (filters.sort) params.set('sort', filters.sort);
  if (filters.order) params.set('order', filters.order);
  const query = params.toString();
  return `/client-keys${query ? `?${query}` : ''}`;
}

export function fetchClientKeys(
  request: APIKeysRequest,
  filters: APIKeyListFilters,
) {
  return requestWithFallback<APIKeysListResponse>(
    request,
    buildClientKeysPath(filters),
  );
}

export function createClientKey(request: APIKeysRequest, name: string) {
  return requestWithFallback<APIKeyCreateResponse>(request, '/client-keys', {
    method: 'POST',
    body: JSON.stringify({ name }),
  });
}

export function updateClientKey(
  request: APIKeysRequest,
  id: string,
  payload: { name?: string; status?: string },
) {
  return requestWithFallback<APIKeyMutationResponse>(
    request,
    `/client-keys/${id}`,
    {
      method: 'PATCH',
      body: JSON.stringify(payload),
    },
  );
}

export function deleteClientKey(request: APIKeysRequest, id: string) {
  return requestWithFallback<APIKeyMutationResponse>(
    request,
    `/client-keys/${id}`,
    {
      method: 'DELETE',
    },
  );
}

export function useClientKeysQuery(filters: APIKeyListFilters) {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: [...clientKeysQueryKey, filters],
    queryFn: () => fetchClientKeys(request, filters),
  });
}

export function useClientKeyUsageQuery(
  id: string | null,
  filters: APIKeyUsageFilters,
) {
  const { request } = useAdminRuntime();
  return useQuery({
    queryKey: [...clientKeyUsageQueryKey, id, filters],
    enabled: Boolean(id),
    queryFn: () => {
      const params = new URLSearchParams();
      if (filters.from) params.set('from', filters.from);
      if (filters.to) params.set('to', filters.to);
      if (filters.model) params.set('model', filters.model);
      if (filters.endpoint) params.set('endpoint', filters.endpoint);
      if (filters.granularity) params.set('granularity', filters.granularity);
      return requestWithFallback<APIKeyUsageResponse>(
        request,
        `/client-keys/${id}/usage?${params.toString()}`,
      );
    },
  });
}

export function useClientKeyMutations() {
  const { request } = useAdminRuntime();
  const queryClient = useQueryClient();

  const invalidate = async () => {
    await queryClient.invalidateQueries({ queryKey: clientKeysQueryKey });
    await queryClient.invalidateQueries({ queryKey: clientKeyUsageQueryKey });
  };

  return {
    createMutation: useMutation({
      mutationFn: (name: string) => createClientKey(request, name),
      onSuccess: invalidate,
    }),
    updateMutation: useMutation({
      mutationFn: ({
        id,
        payload,
      }: {
        id: string;
        payload: { name?: string; status?: string };
      }) => updateClientKey(request, id, payload),
      onSuccess: invalidate,
    }),
    deleteMutation: useMutation({
      mutationFn: (id: string) => deleteClientKey(request, id),
      onSuccess: invalidate,
    }),
  };
}
