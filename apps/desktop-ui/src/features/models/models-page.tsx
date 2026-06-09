import { Badge } from '@quotio/ui/components/badge';
import { Button } from '@quotio/ui/components/button';
import { Input } from '@quotio/ui/components/input';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@quotio/ui/components/table';
import {
  RiCheckboxCircleLine,
  RiRefreshLine,
  RiSearchLine,
} from '@remixicon/react';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { AdminPageHeader } from '@/components/admin/admin-page-header';
import { CopyButton } from '@/components/admin/copy-button';
import { EmptyState } from '@/components/admin/empty-state';
import { ErrorState } from '@/components/admin/error-state';
import { LoadingState } from '@/components/admin/loading-state';
import { ProviderIcon } from '@/components/admin/provider-icon';
import { useToast } from '@/components/admin/toast-provider';
import { getProviderDisplayName } from '@/features/providers/types';
import { useAdminRuntime } from '@/lib/admin/runtime';
import { useModelCatalogQuery, useModelMutations } from './api';
import type { ModelCatalogItem, ModelCatalogProvider, ModelRow } from './types';

const CAPABILITY_BADGES: Array<{
  key:
    | 'reasoning'
    | 'vision'
    | 'websearch'
    | 'free'
    | 'embedding'
    | 'rerank'
    | 'function';
  label: string;
  className: string;
  title: string;
}> = [
  {
    key: 'reasoning',
    label: 'R',
    className: 'bg-primary/10 text-primary',
    title: 'Reasoning',
  },
  {
    key: 'vision',
    label: 'V',
    className: 'bg-chart-2/10 text-chart-2',
    title: 'Vision',
  },
  {
    key: 'websearch',
    label: 'W',
    className: 'bg-chart-1/10 text-chart-1',
    title: 'Web search',
  },
  {
    key: 'free',
    label: 'F',
    className: 'bg-success/10 text-success',
    title: 'Free',
  },
  {
    key: 'embedding',
    label: 'E',
    className: 'bg-warning/10 text-warning',
    title: 'Embedding',
  },
  {
    key: 'rerank',
    label: 'RR',
    className: 'bg-warning/10 text-warning',
    title: 'Rerank',
  },
  {
    key: 'function',
    label: 'T',
    className: 'bg-danger/10 text-danger',
    title: 'Tools',
  },
];

function getRowId(providerId: string, modelId: string) {
  return `${providerId}::${modelId}`;
}

function flattenProviders(providers: ModelCatalogProvider[]): ModelRow[] {
  return providers.flatMap((provider) =>
    provider.models.map((item) => ({
      rowId: getRowId(provider.provider_id, item.model_id),
      providerId: provider.provider_id,
      providerName: getProviderDisplayName(
        provider.provider_id,
        provider.provider_name,
      ),
      item,
    })),
  );
}

function modelMatchesCapability(
  item: ModelCatalogItem,
  filter:
    | 'reasoning'
    | 'vision'
    | 'websearch'
    | 'free'
    | 'embedding'
    | 'rerank'
    | 'function',
) {
  const text = `${item.model_id} ${item.id}`.toLowerCase();
  const runtimeFlags = item.capabilities ?? {};

  switch (filter) {
    case 'reasoning':
      return (
        text.includes('reasoning') ||
        text.includes('thinking') ||
        text.includes('o1') ||
        text.includes('o3') ||
        text.includes('o4') ||
        text.includes('opus')
      );
    case 'vision':
      return (
        text.includes('vision') ||
        text.includes('visual') ||
        text.includes('image') ||
        text.includes('vl')
      );
    case 'websearch':
      return text.includes('search') || text.includes('web');
    case 'free':
      return (
        text.includes('free') || text.includes('mini') || text.includes('lite')
      );
    case 'embedding':
      return Boolean(runtimeFlags.embeddings) || text.includes('embed');
    case 'rerank':
      return text.includes('rerank');
    case 'function':
      return Boolean(runtimeFlags.tools) || text.includes('tool');
  }
}

function CapabilityBadges({ item }: { item: ModelCatalogItem }) {
  const visible = CAPABILITY_BADGES.filter((badge) =>
    modelMatchesCapability(item, badge.key),
  );

  if (visible.length === 0) {
    return <span className="text-xs text-muted-foreground">—</span>;
  }

  return (
    <div className="flex flex-wrap gap-1">
      {visible.map((badge) => (
        <span
          key={badge.key}
          className={`inline-flex size-5 items-center justify-center rounded-md text-[10px] font-semibold ${badge.className}`}
          title={badge.title}
        >
          {badge.label}
        </span>
      ))}
    </div>
  );
}

export function ModelsPage() {
  const { t } = useTranslation();
  const { bootstrap } = useAdminRuntime();
  const toast = useToast();
  const catalogQuery = useModelCatalogQuery();
  const mutations = useModelMutations();
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [search, setSearch] = useState('');
  const [savingProviders, setSavingProviders] = useState<Set<string>>(
    new Set(),
  );

  const providers = catalogQuery.data?.providers ?? [];
  const rows = useMemo(() => flattenProviders(providers), [providers]);

  useEffect(() => {
    const nextSelected = new Set<string>();
    for (const row of rows) {
      if (row.item.is_enabled) {
        nextSelected.add(row.rowId);
      }
    }
    setSelected(nextSelected);
  }, [rows]);

  const rowsByProvider = useMemo(() => {
    const grouped = new Map<string, ModelRow[]>();
    for (const row of rows) {
      const current = grouped.get(row.providerId);
      if (current) {
        current.push(row);
      } else {
        grouped.set(row.providerId, [row]);
      }
    }
    return grouped;
  }, [rows]);

  const filteredProviders = useMemo(() => {
    const query = search.trim().toLowerCase();

    return providers
      .map((provider) => ({
        ...provider,
        models: provider.models.filter((item) => {
          return (
            query.length === 0 ||
            `${provider.provider_id} ${getProviderDisplayName(
              provider.provider_id,
              provider.provider_name,
            )} ${item.model_id} ${item.id}`
              .toLowerCase()
              .includes(query)
          );
        }),
      }))
      .filter((provider) => provider.models.length > 0);
  }, [providers, search]);

  const filteredRows = useMemo(
    () => flattenProviders(filteredProviders),
    [filteredProviders],
  );

  const persistSelection = useCallback(
    async (
      previousSelected: Set<string>,
      nextSelected: Set<string>,
      affectedProviders: Set<string>,
      successMessage: string,
    ) => {
      if (affectedProviders.size === 0) {
        return;
      }

      setSelected(nextSelected);
      setSavingProviders((current) => {
        const next = new Set(current);
        for (const providerId of affectedProviders) {
          next.add(providerId);
        }
        return next;
      });

      try {
        await Promise.all(
          [...affectedProviders].map(async (providerId) => {
            const providerRows = rowsByProvider.get(providerId) ?? [];
            const selectedModels = providerRows
              .filter((row) => nextSelected.has(row.rowId))
              .map((row) => row.item.model_id);
            const models =
              selectedModels.length === providerRows.length
                ? null
                : selectedModels;

            await mutations.setEnabledModelsMutation.mutateAsync({
              providerId,
              models,
            });
          }),
        );

        toast.success(successMessage);
      } catch (error) {
        setSelected(previousSelected);
        toast.error(
          error instanceof Error
            ? error.message
            : t('models.messages.saveFailed'),
        );
      } finally {
        setSavingProviders((current) => {
          const next = new Set(current);
          for (const providerId of affectedProviders) {
            next.delete(providerId);
          }
          return next;
        });
      }
    },
    [mutations.setEnabledModelsMutation, rowsByProvider, t, toast],
  );

  const toggleRow = useCallback(
    async (row: ModelRow) => {
      const previous = new Set(selected);
      const next = new Set(selected);

      if (next.has(row.rowId)) {
        next.delete(row.rowId);
      } else {
        next.add(row.rowId);
      }

      await persistSelection(
        previous,
        next,
        new Set([row.providerId]),
        t('models.messages.filtersUpdated', { provider: row.providerName }),
      );
    },
    [persistSelection, selected, t],
  );

  if (catalogQuery.isLoading) {
    return <LoadingState label={t('models.loading')} />;
  }

  if (catalogQuery.error) {
    return (
      <ErrorState
        title={t('models.failedToLoad')}
        description={
          catalogQuery.error instanceof Error
            ? catalogQuery.error.message
            : t('common.unknownError')
        }
        actionLabel={t('common.retry')}
        onAction={() => void catalogQuery.refetch()}
      />
    );
  }

  return (
    <div className="space-y-6">
      <AdminPageHeader
        title={t('models.title')}
        description={t('models.description')}
        actions={
          <Button
            variant="outline"
            onClick={() => void catalogQuery.refetch()}
            disabled={catalogQuery.isFetching}
          >
            <RiRefreshLine />
            {t('common.refresh')}
          </Button>
        }
      />

      <div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
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

      {filteredRows.length === 0 ? (
        <EmptyState
          title={t('models.emptyTitle')}
          description={
            rows.length === 0
              ? t('models.emptyDescription')
              : t('models.noMatches')
          }
        />
      ) : (
        <div className="overflow-hidden rounded-xl border border-border">
          <Table>
            <TableHeader>
              <TableRow className="hover:bg-transparent [&>th]:py-2 [&>th]:h-10 text-xs">
                <TableHead>{t('models.columns.provider')}</TableHead>
                <TableHead>{t('models.columns.model')}</TableHead>
                <TableHead>{t('models.columns.capabilities')}</TableHead>
                <TableHead>{t('models.columns.status')}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {filteredRows.map((row) => {
                const isEnabled = selected.has(row.rowId);
                const isBusy = savingProviders.has(row.providerId);

                return (
                  <TableRow
                    key={row.rowId}
                    className="group bg-muted/30 hover:bg-muted/60 [&>td]:py-2"
                  >
                    <TableCell className="align-middle">
                      <div className="flex items-center gap-3">
                        <div className="flex h-6 w-6 shrink-0 items-center justify-center rounded-md border border-border bg-muted">
                          <ProviderIcon
                            provider={row.providerId}
                            className="h-4 w-4"
                          />
                        </div>
                        <span className="font-medium text-foreground text-sm">
                          {row.providerName}
                        </span>
                      </div>
                    </TableCell>
                    <TableCell className="whitespace-normal align-middle">
                      <div className="space-y-1.5">
                        <div className="flex flex-wrap items-center gap-1.5 font-mono font-medium text-foreground">
                          <div>
                            <span className="font-normal text-muted-foreground">
                              {row.providerId}/
                            </span>
                            {row.item.model_id}
                          </div>
                          {row.item.multiplier_label ? (
                            <Badge
                              variant="secondary"
                              className="h-5 px-1.5 text-[10px] not-italic"
                            >
                              {row.item.multiplier_label}
                            </Badge>
                          ) : null}
                          <CopyButton
                            variant="ghost"
                            size="icon-xs"
                            title={t('models.copy')}
                            value={row.item.id}
                            successMessage={t('models.messages.copied', {
                              model: row.item.id,
                            })}
                            errorMessage={t('models.messages.copyFailed')}
                            className="h-5 w-5 opacity-0 transition-opacity focus-visible:opacity-100 group-hover:opacity-100 text-muted-foreground hover:text-foreground"
                          />
                        </div>
                        <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                          {row.item.warnings?.length ? (
                            <span>{t('models.warningBadge')}</span>
                          ) : null}
                        </div>
                      </div>
                    </TableCell>
                    <TableCell className="align-middle">
                      <CapabilityBadges item={row.item} />
                    </TableCell>
                    <TableCell className="align-middle">
                      <Button
                        variant={isEnabled ? 'secondary' : 'outline'}
                        size="xs"
                        disabled={
                          isBusy ||
                          !bootstrap.capabilities.supportsModelSettings
                        }
                        onClick={() => void toggleRow(row)}
                        className={
                          isEnabled
                            ? 'border-success/20 bg-success/10 text-success hover:bg-success/15'
                            : undefined
                        }
                      >
                        {isEnabled ? <RiCheckboxCircleLine /> : null}
                        {isEnabled
                          ? t('models.status.enabled')
                          : t('models.status.disabled')}
                      </Button>
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  );
}
