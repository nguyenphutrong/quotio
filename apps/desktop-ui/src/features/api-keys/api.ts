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

export function useClientKeysQuery(filters: APIKeyListFilters) {
  const { request } = useAdminRuntime();
  const params = new URLSearchParams();
  if (filters.status) params.set('status', filters.status);
  if (filters.q) params.set('q', filters.q);
  if (filters.sort) params.set('sort', filters.sort);
  if (filters.order) params.set('order', filters.order);
  const query = params.toString();

  return useQuery({
    queryKey: [...clientKeysQueryKey, filters],
    queryFn: () =>
      request<APIKeysListResponse>(`/client-keys${query ? `?${query}` : ''}`),
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
      return request<APIKeyUsageResponse>(
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
      mutationFn: (name: string) =>
        request<APIKeyCreateResponse>('/client-keys', {
          method: 'POST',
          body: JSON.stringify({ name }),
        }),
      onSuccess: invalidate,
    }),
    updateMutation: useMutation({
      mutationFn: ({
        id,
        payload,
      }: {
        id: string;
        payload: { name?: string; status?: string };
      }) =>
        request<APIKeyMutationResponse>(`/client-keys/${id}`, {
          method: 'PATCH',
          body: JSON.stringify(payload),
        }),
      onSuccess: invalidate,
    }),
    deleteMutation: useMutation({
      mutationFn: (id: string) =>
        request<APIKeyMutationResponse>(`/client-keys/${id}`, {
          method: 'DELETE',
        }),
      onSuccess: invalidate,
    }),
  };
}
