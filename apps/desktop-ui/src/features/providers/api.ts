import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type {
  ProviderOAuthSession,
  ProviderPayload,
  ProviderResponse,
  ProviderTestSummary,
} from '@/features/providers/types';
import { useAdminRuntime } from '@/lib/admin/runtime';

export function useProvidersQuery() {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: ['providers'],
    queryFn: () => request<ProviderResponse[]>('/providers'),
  });
}

export function useProviderMutations() {
  const { request } = useAdminRuntime();
  const queryClient = useQueryClient();

  const invalidate = async () => {
    await queryClient.invalidateQueries({ queryKey: ['providers'] });
  };

  return {
    validateMutation: useMutation({
      mutationFn: (payload: ProviderPayload) =>
        request<ProviderResponse>('/providers/validate', {
          method: 'POST',
          body: JSON.stringify(payload),
        }),
    }),
    createMutation: useMutation({
      mutationFn: (payload: ProviderPayload) =>
        request<ProviderResponse>('/providers', {
          method: 'POST',
          body: JSON.stringify(payload),
        }),
      onSuccess: invalidate,
    }),
    updateMutation: useMutation({
      mutationFn: ({
        id,
        label,
        disabled,
        headers,
      }: {
        id: string;
        label: string;
        disabled?: boolean;
        headers?: Record<string, string>;
      }) =>
        request<ProviderResponse>(`/providers/${id}`, {
          method: 'PATCH',
          body: JSON.stringify({ label, disabled, headers }),
        }),
      onSuccess: invalidate,
    }),
    deleteMutation: useMutation({
      mutationFn: (id: string) =>
        request<ProviderResponse>(`/providers/${id}`, {
          method: 'DELETE',
        }),
      onSuccess: invalidate,
    }),
    testMutation: useMutation({
      mutationFn: (id: string) =>
        request<ProviderTestSummary>(`/providers/${id}/test`, {
          method: 'POST',
        }),
      onSuccess: invalidate,
    }),
    refreshMutation: useMutation({
      mutationFn: (id: string) =>
        request<ProviderResponse>(`/providers/${id}/refresh`, {
          method: 'POST',
        }),
      onSuccess: invalidate,
    }),
    startOAuthMutation: useMutation({
      mutationFn: ({
        provider,
        method,
      }: {
        provider: string;
        method?: string;
      }) =>
        request<ProviderOAuthSession>('/providers/oauth/start', {
          method: 'POST',
          body: JSON.stringify({ provider, method }),
        }),
    }),
    completeOAuthCallbackMutation: useMutation({
      mutationFn: ({
        sessionId,
        state,
        code,
      }: {
        sessionId: string;
        state: string;
        code: string;
      }) =>
        request<ProviderOAuthSession>('/providers/oauth/callback', {
          method: 'POST',
          body: JSON.stringify({
            session_id: sessionId,
            state,
            code,
          }),
        }),
      onSuccess: invalidate,
    }),
    oauthStatusMutation: useMutation({
      mutationFn: (sessionId: string) =>
        request<ProviderOAuthSession>(`/providers/oauth/sessions/${sessionId}`),
    }),
    syncModelsMutation: useMutation({
      mutationFn: (provider: string) =>
        request<ProviderTestSummary>(`/providers/${provider}/sync`, {
          method: 'POST',
        }),
      onSuccess: invalidate,
    }),
  };
}
