import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type {
  EnabledModelsResponse,
  ModelCatalogResponse,
  ProviderSyncSummary,
} from '@/features/models/types';
import { useAdminRuntime } from '@/lib/admin/runtime';

export function useModelCatalogQuery() {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: ['models', 'catalog'],
    queryFn: () => request<ModelCatalogResponse>('/models/catalog'),
  });
}

export function useModelMutations() {
  const { request } = useAdminRuntime();
  const queryClient = useQueryClient();

  const invalidateCatalog = async () => {
    await queryClient.invalidateQueries({ queryKey: ['models', 'catalog'] });
  };

  return {
    setEnabledModelsMutation: useMutation({
      mutationFn: ({
        providerId,
        models,
      }: {
        providerId: string;
        models: string[] | null;
      }) =>
        request<EnabledModelsResponse>(
          `/providers/${providerId}/enabled-models`,
          {
            method: 'PUT',
            body: JSON.stringify({ models }),
          },
        ),
    }),
    syncProviderModelsMutation: useMutation({
      mutationFn: (providerId: string) =>
        request<ProviderSyncSummary>(`/providers/${providerId}/models/sync`, {
          method: 'POST',
        }),
      onSuccess: invalidateCatalog,
    }),
    invalidateCatalog,
  };
}
