import { Badge } from '@quotio/ui/components/badge';
import { Button } from '@quotio/ui/components/button';
import { Input } from '@quotio/ui/components/input';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@quotio/ui/components/select';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@quotio/ui/components/table';
import {
  RiArrowLeftSLine,
  RiArrowRightSLine,
  RiRefreshLine,
} from '@remixicon/react';
import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { AdminPageHeader } from '@/components/admin/admin-page-header';
import { EmptyState } from '@/components/admin/empty-state';
import { ErrorState } from '@/components/admin/error-state';
import { LoadingState } from '@/components/admin/loading-state';
import { Panel } from '@/components/admin/panel';
import { useToast } from '@/components/admin/toast-provider';
import {
  type UsageStatsFilters,
  useUsageStatsEventsQuery,
  useUsageStatsMutations,
  useUsageStatsStatusQuery,
  useUsageStatsSummaryQuery,
} from './api';
import type { UsageStatsEvent } from './types';

const limitOptions = [50, 100, 250, 500, 1000];

function formatNumber(value?: number | null) {
  return new Intl.NumberFormat().format(value ?? 0);
}

function formatCompact(value?: number | null) {
  const number = value ?? 0;
  if (number >= 1_000_000) return `${(number / 1_000_000).toFixed(1)}M`;
  if (number >= 1_000) return `${(number / 1_000).toFixed(1)}K`;
  return formatNumber(number);
}

function formatCost(value?: number | null) {
  if (typeof value !== 'number') return '-';
  return new Intl.NumberFormat(undefined, {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: 2,
    maximumFractionDigits: 4,
  }).format(value);
}

function formatTimestamp(value: number) {
  if (!value) return '-';
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(value));
}

function displayModel(event: UsageStatsEvent) {
  return event.resolved_model || event.model || event.requested_model || '-';
}

function displayAccount(event: UsageStatsEvent) {
  return event.account || event.account_hash || event.api_key_hash || '-';
}

function KPI({
  label,
  value,
  hint,
}: {
  label: string;
  value: string;
  hint: string;
}) {
  return (
    <Panel className="rounded-lg p-4">
      <div className="text-xs font-medium uppercase text-muted-foreground">
        {label}
      </div>
      <div className="mt-2 text-2xl font-semibold tabular-nums">{value}</div>
      <div className="mt-1 text-xs text-muted-foreground">{hint}</div>
    </Panel>
  );
}

export function UsageStatsPage() {
  const { t } = useTranslation();
  const toast = useToast();
  const [filters, setFilters] = useState<UsageStatsFilters>({
    account: '',
    model: '',
    channel: '',
    authIndex: '',
    limit: 100,
    offset: 0,
  });

  const statusQuery = useUsageStatsStatusQuery();
  const status = statusQuery.data;
  const dataEnabled = Boolean(status?.enabled && status.open);
  const summaryQuery = useUsageStatsSummaryQuery(filters, dataEnabled);
  const eventsQuery = useUsageStatsEventsQuery(filters, dataEnabled);
  const mutations = useUsageStatsMutations();

  const handleRefresh = () => {
    void statusQuery.refetch();
    void summaryQuery.refetch();
    void eventsQuery.refetch();
  };

  const handleSyncPrices = async () => {
    try {
      const result = await mutations.syncModelPricesMutation.mutateAsync();
      toast.success(
        t('usageStats.messages.pricesSynced', {
          imported: result.imported,
          skipped: result.skipped,
        }),
      );
    } catch (error) {
      toast.error(
        error instanceof Error
          ? error.message
          : t('usageStats.messages.pricesSyncFailed'),
      );
    }
  };

  const summary = summaryQuery.data;
  const events = eventsQuery.data?.events ?? [];

  return (
    <div className="space-y-6">
      <AdminPageHeader
        title={t('usageStats.title')}
        description={t('usageStats.description')}
        actions={
          <div className="flex items-center gap-2">
            <Button variant="outline" onClick={handleRefresh}>
              <RiRefreshLine />
              {t('common.refresh')}
            </Button>
            <Button
              variant="outline"
              onClick={() => void handleSyncPrices()}
              disabled={mutations.syncModelPricesMutation.isPending}
            >
              <RiRefreshLine />
              {t('usageStats.actions.syncPrices')}
            </Button>
          </div>
        }
      />

      {statusQuery.isLoading ? (
        <LoadingState label={t('common.loading')} />
      ) : null}

      {statusQuery.isError ? (
        <ErrorState
          title={t('usageStats.failedToLoad')}
          description={statusQuery.error.message}
          onAction={() => void statusQuery.refetch()}
        />
      ) : null}

      {status && !dataEnabled ? (
        <EmptyState
          title={t('usageStats.disabledTitle')}
          description={t('usageStats.disabledDescription')}
        />
      ) : null}

      {status ? (
        <Panel className="flex flex-col gap-3 rounded-lg md:flex-row md:items-center md:justify-between">
          <div className="flex flex-wrap items-center gap-2">
            <Badge variant={dataEnabled ? 'default' : 'secondary'}>
              {dataEnabled
                ? t('usageStats.status.ready')
                : t('usageStats.status.disabled')}
            </Badge>
            <span className="text-sm text-muted-foreground">
              {t('usageStats.priceCount', {
                count: status.model_prices_count ?? 0,
              })}
            </span>
          </div>
          {status.model_prices_sync_error ? (
            <span className="text-sm text-destructive">
              {status.model_prices_sync_error}
            </span>
          ) : null}
        </Panel>
      ) : null}

      <Panel className="rounded-lg">
        <div className="grid gap-3 md:grid-cols-5">
          <Input
            value={filters.account}
            onChange={(event) =>
              setFilters((current) => ({
                ...current,
                account: event.target.value,
                offset: 0,
              }))
            }
            placeholder={t('usageStats.filters.account')}
          />
          <Input
            value={filters.model}
            onChange={(event) =>
              setFilters((current) => ({
                ...current,
                model: event.target.value,
                offset: 0,
              }))
            }
            placeholder={t('usageStats.filters.model')}
          />
          <Input
            value={filters.channel}
            onChange={(event) =>
              setFilters((current) => ({
                ...current,
                channel: event.target.value,
                offset: 0,
              }))
            }
            placeholder={t('usageStats.filters.channel')}
          />
          <Input
            value={filters.authIndex}
            onChange={(event) =>
              setFilters((current) => ({
                ...current,
                authIndex: event.target.value,
                offset: 0,
              }))
            }
            placeholder={t('usageStats.filters.authIndex')}
          />
          <Select
            value={String(filters.limit)}
            onValueChange={(value) =>
              setFilters((current) => ({
                ...current,
                limit: Number(value),
                offset: 0,
              }))
            }
          >
            <SelectTrigger>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {limitOptions.map((limit) => (
                <SelectItem key={limit} value={String(limit)}>
                  {t('usageStats.limit', { count: limit })}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </Panel>

      {summary ? (
        <div className="grid gap-3 md:grid-cols-3 xl:grid-cols-6">
          <KPI
            label={t('usageStats.summary.requests')}
            value={formatNumber(summary.total_requests)}
            hint={t('usageStats.summary.requestsHint')}
          />
          <KPI
            label={t('usageStats.summary.success')}
            value={formatNumber(summary.success_count)}
            hint={t('usageStats.summary.failures', {
              count: summary.failure_count,
            })}
          />
          <KPI
            label={t('usageStats.summary.tokens')}
            value={formatCompact(summary.tokens.total_tokens)}
            hint={t('usageStats.summary.tokensHint', {
              prompt: formatCompact(summary.tokens.prompt_tokens),
              completion: formatCompact(summary.tokens.completion_tokens),
            })}
          />
          <KPI
            label={t('usageStats.summary.reasoning')}
            value={formatCompact(summary.tokens.reasoning_tokens)}
            hint={t('usageStats.summary.cache', {
              count: formatCompact(summary.tokens.cache_tokens),
            })}
          />
          <KPI
            label={t('usageStats.summary.cost')}
            value={formatCost(summary.estimated_cost_usd)}
            hint={t('usageStats.summary.latency', {
              value:
                summary.latency_count && summary.latency_sum_ms
                  ? Math.round(summary.latency_sum_ms / summary.latency_count)
                  : '-',
            })}
          />
          <KPI
            label={t('usageStats.summary.offset')}
            value={formatNumber(filters.offset)}
            hint={t('usageStats.summary.offsetHint')}
          />
        </div>
      ) : null}

      {summaryQuery.isError || eventsQuery.isError ? (
        <ErrorState
          title={t('usageStats.failedToLoad')}
          description={
            summaryQuery.error?.message ??
            eventsQuery.error?.message ??
            t('common.unknownError')
          }
          onAction={handleRefresh}
        />
      ) : null}

      <Panel className="overflow-hidden rounded-lg p-0">
        <div className="flex items-center justify-between border-b px-5 py-4">
          <div>
            <h2 className="font-medium">{t('usageStats.events.title')}</h2>
            <p className="text-sm text-muted-foreground">
              {t('usageStats.events.description')}
            </p>
          </div>
          <div className="flex items-center gap-2">
            <Button
              variant="outline"
              size="icon"
              disabled={filters.offset === 0}
              onClick={() =>
                setFilters((current) => ({
                  ...current,
                  offset: Math.max(0, current.offset - current.limit),
                }))
              }
            >
              <RiArrowLeftSLine />
            </Button>
            <Button
              variant="outline"
              size="icon"
              disabled={events.length < filters.limit}
              onClick={() =>
                setFilters((current) => ({
                  ...current,
                  offset: current.offset + current.limit,
                }))
              }
            >
              <RiArrowRightSLine />
            </Button>
          </div>
        </div>
        {eventsQuery.isLoading ? (
          <LoadingState label={t('usageStats.loadingEvents')} />
        ) : events.length === 0 ? (
          <EmptyState
            title={t('usageStats.events.emptyTitle')}
            description={t('usageStats.events.emptyDescription')}
          />
        ) : (
          <div className="overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>{t('usageStats.columns.time')}</TableHead>
                  <TableHead>{t('usageStats.columns.account')}</TableHead>
                  <TableHead>{t('usageStats.columns.model')}</TableHead>
                  <TableHead>{t('usageStats.columns.channel')}</TableHead>
                  <TableHead>{t('usageStats.columns.status')}</TableHead>
                  <TableHead>{t('usageStats.columns.tokens')}</TableHead>
                  <TableHead>{t('usageStats.columns.latency')}</TableHead>
                  <TableHead>{t('usageStats.columns.cost')}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {events.map((event) => (
                  <TableRow key={event.id}>
                    <TableCell className="whitespace-nowrap text-xs">
                      {formatTimestamp(event.timestamp_ms)}
                    </TableCell>
                    <TableCell className="max-w-44 truncate font-mono text-xs">
                      {displayAccount(event)}
                    </TableCell>
                    <TableCell className="max-w-64 truncate">
                      {displayModel(event)}
                      <div className="truncate text-xs text-muted-foreground">
                        {event.endpoint || event.path}
                      </div>
                    </TableCell>
                    <TableCell>
                      {event.channel || event.provider || '-'}
                    </TableCell>
                    <TableCell>
                      <Badge
                        variant={event.failed ? 'destructive' : 'secondary'}
                      >
                        {event.status_code || (event.failed ? 'ERR' : 'OK')}
                      </Badge>
                    </TableCell>
                    <TableCell className="tabular-nums">
                      {formatCompact(event.total_tokens)}
                    </TableCell>
                    <TableCell className="tabular-nums">
                      {event.latency_ms ? `${event.latency_ms} ms` : '-'}
                    </TableCell>
                    <TableCell className="tabular-nums">
                      {formatCost(event.estimated_cost_usd)}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </Panel>
    </div>
  );
}
