import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAdminRuntime } from '@/lib/admin/runtime';
import type { AccountSwitchingStatus, QuotaView } from './types';

const quotaQueryKey = ['quota-view'];
export const quotaAutoRefreshIntervalMs = 5 * 60_000;

export function useQuotaQuery() {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: quotaQueryKey,
    queryFn: () => request<QuotaView>('/quota'),
    refetchInterval: quotaAutoRefreshIntervalMs,
  });
}

export function useQuotaMutations() {
  const { request } = useAdminRuntime();
  const queryClient = useQueryClient();

  const invalidate = async () => {
    await queryClient.invalidateQueries({ queryKey: quotaQueryKey });
  };

  return {
    invalidate,
    refreshAllMutation: useMutation({
      mutationFn: () =>
        request<QuotaView>('/quota/refresh', {
          method: 'POST',
        }),
      onSuccess: (data) => {
        queryClient.setQueryData(quotaQueryKey, data);
      },
    }),
    refreshAccountMutation: useMutation({
      mutationFn: ({
        provider,
        credentialId,
      }: {
        provider: string;
        credentialId: string;
      }) =>
        request<QuotaView>(`/quota/refresh/${provider}/${credentialId}`, {
          method: 'POST',
        }),
      onSuccess: (data) => {
        queryClient.setQueryData(quotaQueryKey, data);
      },
    }),
    switchAccountMutation: useMutation({
      mutationFn: ({ provider, id }: { provider: string; id: string }) =>
        request<AccountSwitchingStatus>(
          `/quota/auth-switching/${provider}/active`,
          {
            method: 'PUT',
            body: JSON.stringify({ id }),
          },
        ),
      onSuccess: invalidate,
    }),
  };
}
