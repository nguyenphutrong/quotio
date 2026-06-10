import { Button } from '@quotio/ui/components/button';
import { Input } from '@quotio/ui/components/input';
import { RiAddLine, RiRefreshLine, RiSearchLine } from '@remixicon/react';
import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { AdminPageHeader } from '@/components/admin/admin-page-header';
import { EmptyState } from '@/components/admin/empty-state';
import { ErrorState } from '@/components/admin/error-state';
import { LoadingState } from '@/components/admin/loading-state';
import { useToast } from '@/components/admin/toast-provider';
import { ProviderDialog } from '@/features/providers/provider-dialog';
import { ProvidersTable } from '@/features/providers/providers-table';
import type {
  ProviderPayload,
  ProviderResponse,
} from '@/features/providers/types';
import {
  getProviderDisplayName,
  normalizeProviderId,
  providerCatalog,
} from '@/features/providers/types';
import { useProviderMutations, useProvidersQuery } from './api';

export function ProvidersPage() {
  const { t } = useTranslation();
  const { success } = useToast();
  const providersQuery = useProvidersQuery();
  const mutations = useProviderMutations();
  const [editingProviderId, setEditingProviderId] = useState<string | null>(
    null,
  );
  const [validationPreview, setValidationPreview] =
    useState<ProviderResponse | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [search, setSearch] = useState('');

  const [isAddProviderOpen, setIsAddProviderOpen] = useState(false);
  const [initialProviderKey, setInitialProviderKey] = useState<
    string | undefined
  >();

  const providers = providersQuery.data ?? [];
  const filteredProviders = providers.filter((provider) => {
    const haystack =
      `${provider.id} ${provider.label} ${provider.provider} ${getProviderDisplayName(provider.provider)}`.toLowerCase();
    return haystack.includes(search.toLowerCase());
  });
  const editingProvider =
    providers.find((provider) => provider.id === editingProviderId) ?? null;

  if (providersQuery.isLoading) {
    return <LoadingState label={t('providers.loading')} />;
  }

  if (providersQuery.error) {
    return (
      <ErrorState
        title={t('providers.failedToLoad')}
        description={
          providersQuery.error instanceof Error
            ? providersQuery.error.message
            : t('providers.unknownError')
        }
        actionLabel={t('common.retry')}
        onAction={() => void providersQuery.refetch()}
      />
    );
  }

  return (
    <div className="space-y-6 h-full flex flex-col">
      <AdminPageHeader
        title={t('providers.title')}
        description={t('providers.description')}
        actions={
          <div className="flex items-center gap-2">
            <Button
              variant="outline"
              onClick={() => void providersQuery.refetch()}
            >
              <RiRefreshLine />
              {t('common.refresh')}
            </Button>
            <Button
              onClick={() => {
                setValidationPreview(null);
                setInitialProviderKey(undefined);
                setIsAddProviderOpen(true);
              }}
            >
              <RiAddLine />
              {t('providers.actions.addProvider')}
            </Button>
          </div>
        }
      />
      <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
        <div className="relative w-full lg:max-w-md">
          <RiSearchLine className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            className="pl-9"
            placeholder={t('models.searchPlaceholder')}
            value={search}
            onChange={(event) => setSearch(event.target.value)}
          />
        </div>
      </div>

      {filteredProviders.length === 0 ? (
        <EmptyState
          title={t('providers.empty.noMatchTitle')}
          description={
            providers.length === 0
              ? t('providers.empty.noneDescription')
              : t('providers.empty.filteredDescription')
          }
        />
      ) : (
        <ProvidersTable
          providers={filteredProviders}
          editingProviderId={editingProviderId}
          onSelect={(provider) => {
            const providerKey = normalizeProviderId(provider.provider);
            const isEditableProvider =
              !providerCatalog[providerKey] || providerKey === 'opencode-go';
            if (!isEditableProvider) {
              return;
            }
            setEditingProviderId(provider.id);
            setValidationPreview(null);
          }}
          onTest={async (provider) => {
            setBusyId(provider.id);
            try {
              const result = await mutations.testMutation.mutateAsync(
                provider.id,
              );
              success(
                t('providers.messages.tested', {
                  name: provider.label || provider.id,
                  provider: result.provider,
                  time: new Date(result.checked_at).toLocaleTimeString(),
                }),
              );
            } finally {
              setBusyId(null);
            }
          }}
          onRefresh={async (provider) => {
            setBusyId(provider.id);
            try {
              await mutations.refreshMutation.mutateAsync(provider.id);
              success(
                t('providers.messages.tokenRefreshed', {
                  name: provider.label || provider.id,
                }),
              );
            } finally {
              setBusyId(null);
            }
          }}
          onToggleDisabled={async (provider) => {
            setBusyId(provider.id);
            try {
              const updated = await mutations.updateMutation.mutateAsync({
                id: provider.id,
                label: provider.label,
                disabled: !provider.disabled,
              });
              success(
                t(
                  updated.disabled
                    ? 'providers.messages.disabled'
                    : 'providers.messages.enabled',
                  { name: updated.label || updated.id },
                ),
              );
            } finally {
              setBusyId(null);
            }
          }}
          onDelete={async (provider) => {
            setBusyId(provider.id);
            try {
              await mutations.deleteMutation.mutateAsync(provider.id);
              setEditingProviderId((current) =>
                current === provider.id ? null : current,
              );
              success(
                t('providers.messages.deleted', {
                  name: provider.label || provider.id,
                }),
              );
            } finally {
              setBusyId(null);
            }
          }}
          onAddConnection={(providerKey) => {
            setValidationPreview(null);
            setInitialProviderKey(providerKey);
            setIsAddProviderOpen(true);
          }}
          busyId={busyId}
        />
      )}

      <ProviderDialog
        key={
          isAddProviderOpen ? 'create-provider-open' : 'create-provider-closed'
        }
        open={isAddProviderOpen}
        onOpenChange={(open) => {
          setIsAddProviderOpen(open);
          if (!open) setInitialProviderKey(undefined);
        }}
        mode="create"
        provider={null}
        validationPreview={validationPreview}
        initialProviderKey={initialProviderKey}
        busy={
          mutations.createMutation.isPending ||
          mutations.validateMutation.isPending
        }
        onValidate={async (payload: ProviderPayload) => {
          const preview = await mutations.validateMutation.mutateAsync(payload);
          setValidationPreview(preview);
          success(
            t('providers.messages.validated', {
              provider: preview.provider,
            }),
          );
        }}
        onCreate={async (payload: ProviderPayload) => {
          const created = await mutations.createMutation.mutateAsync(payload);
          setValidationPreview(null);
          success(
            t('providers.messages.created', {
              name: created.label || created.id,
            }),
          );
          setIsAddProviderOpen(false);
          await providersQuery.refetch();
        }}
        onOAuthCreated={async (created) => {
          setValidationPreview(null);
          success(
            t('providers.messages.created', {
              name: created.label || created.id,
            }),
          );
          setIsAddProviderOpen(false);
          await providersQuery.refetch();
        }}
        onUpdate={async () => {}}
      />

      <ProviderDialog
        open={!!editingProviderId}
        onOpenChange={(open) => {
          if (!open) {
            setEditingProviderId(null);
            setValidationPreview(null);
          }
        }}
        mode="edit"
        provider={editingProvider}
        validationPreview={editingProvider}
        busy={mutations.updateMutation.isPending}
        onValidate={async () => {}}
        onCreate={async () => {}}
        onOAuthCreated={async () => {}}
        onUpdate={async ({ id, label, disabled, headers }) => {
          const updated = await mutations.updateMutation.mutateAsync({
            id,
            label,
            disabled,
            headers,
          });
          success(
            t('providers.messages.updated', {
              name: updated.label || updated.id,
            }),
          );
          setEditingProviderId(null);
          await providersQuery.refetch();
        }}
      />
    </div>
  );
}
