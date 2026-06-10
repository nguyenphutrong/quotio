import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type {
  EnabledModelsResponse,
  ModelCatalogResponse,
  ProviderSyncSummary,
} from '@/features/models/types';
import { useAdminRuntime } from '@/lib/admin/runtime';

type ModelsRequest = <T>(path: string, init?: RequestInit) => Promise<T>;

export function fetchModelCatalog(request: ModelsRequest) {
  return request<ModelCatalogResponse>('/models/catalog');
}

export function setEnabledModels(
  request: ModelsRequest,
  providerId: string,
  models: string[] | null,
) {
  return request<EnabledModelsResponse>(
    `/providers/${providerId}/enabled-models`,
    {
      method: 'PUT',
      body: JSON.stringify({ models }),
    },
  );
}

export function syncProviderModels(request: ModelsRequest, providerId: string) {
  return request<ProviderSyncSummary>(`/providers/${providerId}/models/sync`, {
    method: 'POST',
  });
}

export function useModelCatalogQuery() {
  const { request } = useAdminRuntime();

  return useQuery({
    queryKey: ['models', 'catalog'],
    queryFn: () => fetchModelCatalog(request),
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
      }) => setEnabledModels(request, providerId, models),
    }),
    syncProviderModelsMutation: useMutation({
      mutationFn: (providerId: string) =>
        syncProviderModels(request, providerId),
      onSuccess: invalidateCatalog,
    }),
    invalidateCatalog,
  };
}
