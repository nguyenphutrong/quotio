import type { RuntimeStatus } from '@quotio/desktop-contract/generated';
import { Button } from '@quotio/ui/components/button';
import {
  RiArrowRightUpLine,
  RiCoinsLine,
  RiPulseLine,
  RiServerLine,
} from '@remixicon/react';
import { useCallback, useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { AdminPageHeader } from '@/components/admin/admin-page-header';
import { ErrorState } from '@/components/admin/error-state';
import { LoadingState } from '@/components/admin/loading-state';
import { MetricCard } from '@/components/admin/metric-card';
import { Panel } from '@/components/admin/panel';
import { StaleDataBanner } from '@/components/admin/stale-data-banner';
import { StatusBadge } from '@/components/admin/status-badge';
import { useOverviewQueries } from '@/features/overview/api';
import type { QuotaProviderSummary } from '@/features/overview/types';
import { getProviderDisplayName } from '@/features/providers/types';
import { useAdminRuntime } from '@/lib/admin/runtime';

function formatCurrency(value: number, locale: string) {
  return new Intl.NumberFormat(locale, {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: 2,
    maximumFractionDigits: 4,
  }).format(value);
}

function formatNumber(value: number, locale: string) {
  return new Intl.NumberFormat(locale).format(value);
}

export function OverviewPage() {
  const { t, i18n } = useTranslation();
  const { bootstrap } = useAdminRuntime();
  const { pingQuery, healthQuery, logsSummaryQuery, quotaQuery } =
    useOverviewQueries();

  const isLoading =
    pingQuery.isLoading ||
    healthQuery.isLoading ||
    logsSummaryQuery.isLoading ||
    quotaQuery.isLoading;

  const error =
    pingQuery.error ??
    healthQuery.error ??
    logsSummaryQuery.error ??
    quotaQuery.error;

  if (isLoading) {
    return <LoadingState label={t('overview.loadingData')} />;
  }

  if (error) {
    return (
      <ErrorState
        title={t('overview.failedToLoad')}
        description={
          error instanceof Error ? error.message : 'Unknown overview error'
        }
        actionLabel={t('common.retry')}
        onAction={() => {
          void pingQuery.refetch();
          void healthQuery.refetch();
          void logsSummaryQuery.refetch();
          void quotaQuery.refetch();
        }}
      />
    );
  }

  const logsSummary = logsSummaryQuery.data;
  const health = healthQuery.data;
  const quota = quotaQuery.data;

  if (!logsSummary || !health || !quota) {
    return (
      <ErrorState
        title={t('overview.incompleteData')}
        description={t('overview.incompleteDataDesc')}
        actionLabel={t('common.retry')}
        onAction={() => {
          void pingQuery.refetch();
          void healthQuery.refetch();
          void logsSummaryQuery.refetch();
          void quotaQuery.refetch();
        }}
      />
    );
  }
  const staleProviders = quota.providers.filter(
    (provider: QuotaProviderSummary) => provider.stale_count > 0,
  );

  return (
    <div className="space-y-6">
      <AdminPageHeader
        title={t('overview.title')}
        description={t('overview.description')}
        actions={
          <Button
            variant="outline"
            onClick={() => {
              void pingQuery.refetch();
              void healthQuery.refetch();
              void logsSummaryQuery.refetch();
              void quotaQuery.refetch();
            }}
          >
            {t('overview.refreshSnapshot')}
          </Button>
        }
      />

      {staleProviders.length > 0 ? (
        <StaleDataBanner
          message={t('overview.staleBanner', { count: staleProviders.length })}
        />
      ) : null}

      {bootstrap.capabilities.supportsProxyControl ? (
        <ProxyRuntimePanel />
      ) : null}

      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <MetricCard
          label={t('overview.gatewayStatus')}
          value={pingQuery.data ? t('overview.healthy') : t('overview.unknown')}
          hint={t('overview.providerGroupsHint', {
            count: Object.keys(health.providers).length,
          })}
          icon={<RiPulseLine />}
          tone="success"
        />
        <MetricCard
          label={t('overview.totalRequests')}
          value={formatNumber(logsSummary.total_requests, i18n.language)}
          hint={t('overview.streamingHint', {
            count: formatNumber(logsSummary.stream_requests, i18n.language),
          })}
          icon={<RiServerLine />}
        />
        <MetricCard
          label={t('overview.totalTokens')}
          value={formatNumber(logsSummary.total_tokens, i18n.language)}
          hint={t('overview.tokensHint', {
            prompt: formatNumber(logsSummary.prompt_tokens, i18n.language),
            completion: formatNumber(
              logsSummary.completion_tokens,
              i18n.language,
            ),
          })}
          icon={<RiArrowRightUpLine />}
        />
        <MetricCard
          label={t('overview.estimatedCost')}
          value={formatCurrency(logsSummary.estimated_cost_usd, i18n.language)}
          hint={t('overview.savingsHint', {
            amount: formatCurrency(
              logsSummary.estimated_savings_usd,
              i18n.language,
            ),
          })}
          icon={<RiCoinsLine />}
        />
      </div>

      <div className="grid gap-4 xl:grid-cols-[1.4fr_1fr]">
        <Panel>
          <div className="flex items-center justify-between gap-4">
            <div>
              <h2 className="text-sm font-semibold text-foreground">
                {t('overview.providerHealth')}
              </h2>
              <p className="text-sm text-muted-foreground">
                {t('overview.providerHealthDesc')}
              </p>
            </div>
            <StatusBadge tone="success">{t('overview.snapshot')}</StatusBadge>
          </div>
          <div className="mt-4 overflow-hidden rounded-lg border border-border">
            <table className="w-full text-left text-sm">
              <thead className="bg-muted text-muted-foreground">
                <tr>
                  <th className="px-4 py-3 font-medium">
                    {t('overview.provider')}
                  </th>
                  <th className="px-4 py-3 font-medium">
                    {t('overview.credentialEntries')}
                  </th>
                </tr>
              </thead>
              <tbody>
                {Object.entries(health.providers).map(([provider, entries]) => {
                  const count = Array.isArray(entries) ? entries.length : 0;

                  return (
                    <tr key={provider} className="border-t border-border">
                      <td className="px-4 py-3 font-medium text-foreground">
                        {getProviderDisplayName(provider)}
                      </td>
                      <td className="px-4 py-3 text-muted-foreground">
                        {count}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </Panel>

        <Panel>
          <h2 className="text-sm font-semibold text-foreground">
            {t('overview.operationalCounters')}
          </h2>
          <div className="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-1">
            <CounterRow
              label={t('overview.affinityBindings')}
              value={health.affinity.bindings?.length ?? 0}
            />
            <CounterRow
              label={t('overview.concurrencyRecords')}
              value={health.concurrency.length}
            />
            <CounterRow
              label={t('overview.virtualRoutes')}
              value={health.virtual_routes.length}
            />
            <CounterRow
              label={t('overview.providerCooldowns')}
              value={health.provider_cooldowns.length}
            />
          </div>
        </Panel>
      </div>

      <div className="grid gap-4 xl:grid-cols-[1.2fr_1fr]">
        <Panel>
          <div className="flex items-center justify-between gap-4">
            <div>
              <h2 className="text-sm font-semibold text-foreground">
                {t('overview.quotaSnapshot')}
              </h2>
              <p className="text-sm text-muted-foreground">
                {t('overview.quotaSnapshotDesc')}
              </p>
            </div>
            <StatusBadge tone="neutral">
              {t('overview.providerCount', { count: quota.providers.length })}
            </StatusBadge>
          </div>
          <div className="mt-4 overflow-hidden rounded-lg border border-border">
            <table className="w-full text-left text-sm">
              <thead className="bg-muted text-muted-foreground">
                <tr>
                  <th className="px-4 py-3 font-medium">
                    {t('overview.provider')}
                  </th>
                  <th className="px-4 py-3 font-medium">Accounts</th>
                  <th className="px-4 py-3 font-medium">Stale / Error</th>
                </tr>
              </thead>
              <tbody>
                {quota.providers.map((provider: QuotaProviderSummary) => (
                  <tr
                    key={provider.provider}
                    className="border-t border-border"
                  >
                    <td className="px-4 py-3 font-medium text-foreground">
                      {getProviderDisplayName(provider.provider)}
                    </td>
                    <td className="px-4 py-3">
                      <StatusBadge
                        tone={provider.stale_count > 0 ? 'warning' : 'success'}
                      >
                        {String(provider.accounts)}
                      </StatusBadge>
                    </td>
                    <td className="px-4 py-3 text-muted-foreground">
                      {provider.stale_count}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Panel>

        <Panel>
          <h2 className="text-sm font-semibold text-foreground">
            {t('overview.runtimeCapabilities')}
          </h2>
          <div className="mt-4 space-y-3">
            {Object.entries(health.runtime).map(([runtime, capability]) => {
              const capabilityRecord =
                capability && typeof capability === 'object'
                  ? (capability as Record<string, unknown>)
                  : {};

              return (
                <div
                  key={runtime}
                  className="rounded-lg border border-border bg-muted/50 p-4"
                >
                  <div className="flex items-center justify-between gap-3">
                    <p className="font-medium text-foreground">{runtime}</p>
                    <StatusBadge tone="neutral">
                      {t('overview.flagCount', {
                        count: Object.keys(capabilityRecord).length,
                      })}
                    </StatusBadge>
                  </div>
                  <pre className="mt-3 overflow-x-auto whitespace-pre-wrap font-mono text-xs leading-5 text-muted-foreground">
                    {JSON.stringify(capabilityRecord, null, 2)}
                  </pre>
                </div>
              );
            })}
          </div>
        </Panel>
      </div>
    </div>
  );
}

function ProxyRuntimePanel() {
  const { t } = useTranslation();
  const { runtimeRestart, runtimeStart, runtimeStatus, runtimeStop } =
    useAdminRuntime();
  const [status, setStatus] = useState<RuntimeStatus | null>(null);
  const [busy, setBusy] = useState<'start' | 'stop' | 'restart' | null>(null);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      setError(null);
      setStatus(await runtimeStatus());
    } catch (error) {
      setError(
        error instanceof Error ? error.message : t('common.unknownError'),
      );
    }
  }, [runtimeStatus, t]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const run = async (
    action: 'start' | 'stop' | 'restart',
    command: () => Promise<RuntimeStatus>,
  ) => {
    setBusy(action);
    setError(null);
    try {
      setStatus(await command());
    } catch (error) {
      setError(
        error instanceof Error ? error.message : t('common.unknownError'),
      );
    } finally {
      setBusy(null);
    }
  };

  const isRunning = status?.state === 'managed';
  const disabled = busy !== null;

  return (
    <Panel>
      <div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-3">
            <h2 className="text-sm font-semibold text-foreground">
              {t('overview.proxyRuntime.title')}
            </h2>
            <StatusBadge tone={isRunning ? 'success' : 'neutral'}>
              {isRunning
                ? t('overview.proxyRuntime.status.running')
                : t('overview.proxyRuntime.status.stopped')}
            </StatusBadge>
          </div>
          <p className="mt-1 text-sm text-muted-foreground">
            {status?.endpoint ?? t('overview.proxyRuntime.noEndpoint')}
          </p>
          {error ? <p className="mt-2 text-danger text-sm">{error}</p> : null}
        </div>

        <div className="flex flex-col-reverse gap-2 sm:flex-row">
          <Button
            type="button"
            variant="outline"
            disabled={disabled || !isRunning}
            onClick={() => void run('stop', runtimeStop)}
          >
            {busy === 'stop'
              ? t('overview.proxyRuntime.actions.stopping')
              : t('overview.proxyRuntime.actions.stop')}
          </Button>
          <Button
            type="button"
            variant="outline"
            disabled={disabled}
            onClick={() => void run('restart', runtimeRestart)}
          >
            {busy === 'restart'
              ? t('overview.proxyRuntime.actions.restarting')
              : t('overview.proxyRuntime.actions.restart')}
          </Button>
          <Button
            type="button"
            disabled={disabled || isRunning}
            onClick={() => void run('start', runtimeStart)}
          >
            {busy === 'start'
              ? t('overview.proxyRuntime.actions.starting')
              : t('overview.proxyRuntime.actions.start')}
          </Button>
        </div>
      </div>
    </Panel>
  );
}

function CounterRow({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-lg border border-border bg-muted/50 px-4 py-3">
      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
        {label}
      </p>
      <p className="mt-2 font-mono text-xl tabular-nums font-semibold text-foreground">
        {value}
      </p>
    </div>
  );
}
