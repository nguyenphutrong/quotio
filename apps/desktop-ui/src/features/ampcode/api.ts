import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAdminRuntime } from '@/lib/admin/runtime';
import type {
  AmpCLISetupApplyResponse,
  AmpCLISetupDiffResponse,
  AmpCLISetupRollbackResponse,
  AmpCLISetupStatusResponse,
  AmpCodeResponse,
  AmpModelMapping,
  AmpSimulationResponse,
} from './types';

export function useAmpCodeQuery() {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: ['ampcode'],
    queryFn: () => request<AmpCodeResponse>('/ampcode'),
  });
}

export function useAmpCLISetupStatusQuery() {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: ['ampcode', 'cli-setup'],
    queryFn: () => request<AmpCLISetupStatusResponse>('/ampcode/cli-setup'),
  });
}

export function useAmpCodeMutations() {
  const { request } = useAdminRuntime();
  const queryClient = useQueryClient();

  const invalidate = async () => {
    await queryClient.invalidateQueries({ queryKey: ['ampcode'] });
    await queryClient.invalidateQueries({ queryKey: ['ampcode', 'cli-setup'] });
    await queryClient.invalidateQueries({ queryKey: ['overview'] });
  };

  return {
    saveUpstreamURLMutation: useMutation({
      mutationFn: (value: string) =>
        request<{ upstream_url: string }>('/ampcode/upstream-url', {
          method: 'PATCH',
          body: JSON.stringify({ value }),
        }),
      onSuccess: invalidate,
    }),
    clearUpstreamURLMutation: useMutation({
      mutationFn: () =>
        request<{ upstream_url: string }>('/ampcode/upstream-url', {
          method: 'DELETE',
        }),
      onSuccess: invalidate,
    }),
    saveUpstreamAPIKeyMutation: useMutation({
      mutationFn: (value: string) =>
        request<{ upstream_api_key: string }>('/ampcode/upstream-api-key', {
          method: 'PATCH',
          body: JSON.stringify({ value }),
        }),
      onSuccess: invalidate,
    }),
    clearUpstreamAPIKeyMutation: useMutation({
      mutationFn: () =>
        request<{ upstream_api_key: string }>('/ampcode/upstream-api-key', {
          method: 'DELETE',
        }),
      onSuccess: invalidate,
    }),
    saveModelMappingsMutation: useMutation({
      mutationFn: (value: AmpModelMapping[]) =>
        request('/ampcode/model-mappings', {
          method: 'PATCH',
          body: JSON.stringify({ value }),
        }),
      onSuccess: invalidate,
    }),
    clearModelMappingsMutation: useMutation({
      mutationFn: () =>
        request('/ampcode/model-mappings', {
          method: 'DELETE',
        }),
      onSuccess: invalidate,
    }),
    saveRestrictLocalhostMutation: useMutation({
      mutationFn: (value: boolean) =>
        request<{ restrict_management_to_localhost: boolean }>(
          '/ampcode/restrict-management-to-localhost',
          {
            method: 'PATCH',
            body: JSON.stringify({ value }),
          },
        ),
      onSuccess: invalidate,
    }),
    saveManagementAuthPolicyMutation: useMutation({
      mutationFn: (value: string) =>
        request<{ management_auth_policy: string }>(
          '/ampcode/management-auth-policy',
          {
            method: 'PATCH',
            body: JSON.stringify({ value }),
          },
        ),
      onSuccess: invalidate,
    }),
    saveRoutingModeMutation: useMutation({
      mutationFn: (value: string) =>
        request<{ routing_mode: string }>('/ampcode/routing-mode', {
          method: 'PATCH',
          body: JSON.stringify({ value }),
        }),
      onSuccess: invalidate,
    }),
    simulateMutation: useMutation({
      mutationFn: ({
        route,
        provider,
        model,
      }: {
        route: string;
        provider: string;
        model: string;
      }) =>
        request<AmpSimulationResponse>('/ampcode/simulate', {
          method: 'POST',
          body: JSON.stringify({ route, provider, model }),
        }),
    }),
    ampCLISetupDiffMutation: useMutation({
      mutationFn: () =>
        request<AmpCLISetupDiffResponse>('/ampcode/cli-setup/diff', {
          method: 'POST',
          body: JSON.stringify({}),
        }),
    }),
    ampCLISetupApplyMutation: useMutation({
      mutationFn: () =>
        request<AmpCLISetupApplyResponse>('/ampcode/cli-setup/apply', {
          method: 'POST',
          body: JSON.stringify({}),
        }),
      onSuccess: invalidate,
    }),
    ampCLISetupRollbackMutation: useMutation({
      mutationFn: () =>
        request<AmpCLISetupRollbackResponse>('/ampcode/cli-setup/rollback', {
          method: 'POST',
          body: JSON.stringify({}),
        }),
      onSuccess: invalidate,
    }),
  };
}
