import { Badge } from '@quotio/ui/components/badge';
import { Button } from '@quotio/ui/components/button';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@quotio/ui/components/select';
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from '@quotio/ui/components/sheet';
import { Switch } from '@quotio/ui/components/switch';
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from '@quotio/ui/components/tabs';
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from '@quotio/ui/components/tooltip';
import {
  RiArrowRightUpLine,
  RiCodeLine,
  RiCoinsLine,
  RiErrorWarningLine,
  RiEyeLine,
  RiFileList3Line,
  RiInformationLine,
} from '@remixicon/react';
import { parseAsString, useQueryState } from 'nuqs';
import { useEffect, useMemo, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { AdminPageHeader } from '@/components/admin/admin-page-header';
import { CopyButton } from '@/components/admin/copy-button';
import { EmptyState } from '@/components/admin/empty-state';
import { ErrorState } from '@/components/admin/error-state';
import { LoadingState } from '@/components/admin/loading-state';
import { MetricCard } from '@/components/admin/metric-card';
import { Panel } from '@/components/admin/panel';
import {
  useLoggingSettingsMutation,
  useLoggingSettingsQuery,
  useLogsListQuery,
  useLogsSummaryQuery,
} from './api';
import type { LogEntry } from './types';

const ALL_API_KEYS = '__all__';

function toNumber(value: unknown) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === 'string') {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return 0;
}

function normalizeEntry(entry: LogEntry): LogEntry {
  return {
    ...entry,
    duration_ms: toNumber(entry.duration_ms),
    prompt_tokens: toNumber(entry.prompt_tokens),
    completion_tokens: toNumber(entry.completion_tokens),
    total_tokens: toNumber(entry.total_tokens),
    cache_tokens: toNumber(entry.cache_tokens),
    estimated_cost_usd: toNumber(entry.estimated_cost_usd),
    estimated_savings_usd: toNumber(entry.estimated_savings_usd),
  };
}

function formatAppLabel(rawApp?: string) {
  const value = rawApp?.trim();
  if (!value) {
    return '—';
  }

  const lower = value.toLowerCase();
  const knownAppMatchers: Array<[string, string]> = [
    ['codex desktop', 'Codex Desktop'],
    ['claude code', 'Claude Code'],
    ['githubcopilot', 'GitHub Copilot'],
    ['github copilot', 'GitHub Copilot'],
    ['postmanruntime', 'Postman'],
    ['postman', 'Postman'],
    ['insomnia', 'Insomnia'],
    ['curl/', 'curl'],
    ['openai-python', 'OpenAI SDK'],
    ['openai-node', 'OpenAI SDK'],
    ['openai-sdk', 'OpenAI SDK'],
  ];
  for (const [needle, label] of knownAppMatchers) {
    if (lower.includes(needle)) {
      return label;
    }
  }

  const slashIndex = value.indexOf('/');
  const parenIndex = value.indexOf('(');
  let cutIndex = -1;
  if (slashIndex >= 0 && parenIndex >= 0) {
    cutIndex = Math.min(slashIndex, parenIndex);
  } else if (slashIndex >= 0) {
    cutIndex = slashIndex;
  } else if (parenIndex >= 0) {
    cutIndex = parenIndex;
  }

  if (cutIndex > 0) {
    const compact = value.slice(0, cutIndex).trim();
    if (compact) {
      return compact;
    }
  }

  return value;
}

function isUpstreamValidationError(entry: LogEntry) {
  const errorText = entry.error?.toLowerCase() ?? '';
  const responseText = entry.response_body?.toLowerCase() ?? '';
  const combined = `${errorText}\n${responseText}`;
  if (combined.trim() === '') {
    return false;
  }

  return (
    combined.includes('unsupported parameter') ||
    combined.includes('invalid request') ||
    combined.includes('validation') ||
    combined.includes('invalid type') ||
    combined.includes('extra_body')
  );
}

function displayRequestMethod(entry: LogEntry) {
  const raw = entry.request_method?.trim().toUpperCase();
  if (raw) {
    return raw;
  }
  if (entry.stream) {
    return 'WS';
  }
  return 'POST';
}

function normalizeSlug(value: string) {
  return value.trim().toLowerCase();
}

function displayProviderModel(entry: LogEntry) {
  const provider = normalizeSlug(entry.provider || 'unknown');
  const resolvedModel = normalizeSlug(entry.model || 'unknown');
  const resolved = `${provider}/${resolvedModel}`;

  const requested = (entry.requested_model || '').trim();
  if (!requested) {
    return { primary: resolved, mappedFrom: '' };
  }

  const normalizedRequested = normalizeSlug(requested);
  if (normalizedRequested === resolved) {
    return { primary: resolved, mappedFrom: '' };
  }

  return {
    primary: resolved,
    mappedFrom: normalizedRequested,
  };
}

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

export function LogsPage() {
  const { t, i18n } = useTranslation();
  const summaryQuery = useLogsSummaryQuery();
  const settingsQuery = useLoggingSettingsQuery();
  const [cursor, setCursor] = useQueryState(
    'cursor',
    parseAsString.withDefault(''),
  );
  const [selectedApiKey, setSelectedApiKey] = useQueryState(
    'apiKeyId',
    parseAsString.withDefault(ALL_API_KEYS),
  );
  const [entries, setEntries] = useState<LogEntry[]>([]);
  const [selectedEntry, setSelectedEntry] = useState<LogEntry | null>(null);
  const effectiveAPIKeyID =
    selectedApiKey === ALL_API_KEYS ? '' : selectedApiKey;
  const listQuery = useLogsListQuery(cursor, 50, effectiveAPIKeyID);
  const settingsMutation = useLoggingSettingsMutation();

  const isInitialLoading =
    summaryQuery.isLoading ||
    settingsQuery.isLoading ||
    (listQuery.isLoading && entries.length === 0);

  useEffect(() => {
    if (!listQuery.data) {
      return;
    }
    setEntries((current) => {
      if (cursor === '') {
        return (listQuery.data?.entries ?? []).map(normalizeEntry);
      }
      const existing = new Set(current.map((entry) => entry.request_id));
      const appended = listQuery.data.entries.filter(
        (entry) => !existing.has(entry.request_id),
      );
      if (appended.length === 0) {
        return current;
      }
      return [...current, ...appended.map(normalizeEntry)];
    });
  }, [listQuery.data, cursor]);

  const apiKeyOptions = useMemo(() => {
    const options = new Map<string, string>();
    for (const entry of entries) {
      const id = entry.api_key_id?.trim();
      if (!id) {
        continue;
      }
      const label = entry.api_key_name_snapshot?.trim() || id;
      options.set(id, label);
    }
    if (effectiveAPIKeyID && !options.has(effectiveAPIKeyID)) {
      options.set(effectiveAPIKeyID, effectiveAPIKeyID);
    }
    return Array.from(options.entries()).sort((a, b) =>
      a[1].localeCompare(b[1]),
    );
  }, [entries, effectiveAPIKeyID]);

  if (isInitialLoading) {
    return <LoadingState label={t('logs.loadingData')} />;
  }

  if (summaryQuery.isError || settingsQuery.isError || listQuery.isError) {
    return (
      <ErrorState
        title={t('logs.failedToLoad')}
        description={
          summaryQuery.error instanceof Error
            ? summaryQuery.error.message
            : settingsQuery.error instanceof Error
              ? settingsQuery.error.message
              : listQuery.error instanceof Error
                ? listQuery.error.message
                : t('common.unknownError')
        }
        actionLabel={t('common.retry')}
        onAction={() => {
          void summaryQuery.refetch();
          void settingsQuery.refetch();
          void listQuery.refetch();
        }}
      />
    );
  }

  const summary = summaryQuery.data;
  const settings = settingsQuery.data;
  if (!summary || !settings) {
    return (
      <ErrorState
        title={t('logs.incompleteData')}
        description={t('logs.incompleteDataDesc')}
        actionLabel={t('common.retry')}
        onAction={() => {
          void summaryQuery.refetch();
          void settingsQuery.refetch();
          void listQuery.refetch();
        }}
      />
    );
  }

  const latestEntries = [...entries].sort(
    (a, b) => Date.parse(b.timestamp) - Date.parse(a.timestamp),
  );

  const hasTraffic = summary.total_requests > 0;
  const streamRatio =
    summary.total_requests > 0
      ? Math.round((summary.stream_requests / summary.total_requests) * 100)
      : 0;

  const hasMore = Boolean(listQuery.data?.has_more);
  const nextCursor = listQuery.data?.next_cursor ?? '';

  const loadMore = () => {
    if (!hasMore || !nextCursor) {
      return;
    }
    void setCursor(nextCursor);
  };

  const toggleCaptureBodies = (checked: boolean) => {
    settingsMutation.mutate(checked);
  };

  return (
    <div className="space-y-6">
      <AdminPageHeader
        title={t('logs.title')}
        description={t('logs.description')}
        actions={
          <Button
            variant="outline"
            onClick={() => {
              setEntries([]);
              void setCursor('');
              void summaryQuery.refetch();
              void settingsQuery.refetch();
              void listQuery.refetch();
            }}
          >
            {t('logs.refreshSnapshot')}
          </Button>
        }
      />

      <Panel>
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
          <p className="text-sm font-medium">{t('logs.filters.apiKeys')}</p>
          <Select
            value={selectedApiKey}
            onValueChange={(value) => {
              const next = value || ALL_API_KEYS;
              setEntries([]);
              void setCursor('');
              void setSelectedApiKey(next);
            }}
          >
            <SelectTrigger className="w-full sm:w-72">
              <SelectValue placeholder={t('logs.filters.apiKeysPlaceholder')} />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={ALL_API_KEYS}>
                {t('logs.filters.allApiKeys')}
              </SelectItem>
              {apiKeyOptions.map(([id, label]) => (
                <SelectItem key={id} value={id}>
                  {label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </Panel>

      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <MetricCard
          label={t('logs.totalRequests')}
          value={formatNumber(summary.total_requests, i18n.language)}
          hint={t('logs.streamingHint', {
            count: formatNumber(summary.stream_requests, i18n.language),
          })}
          icon={<RiFileList3Line />}
        />
        <MetricCard
          label={t('logs.totalTokens')}
          value={formatNumber(summary.total_tokens, i18n.language)}
          hint={t('logs.tokensHint', {
            prompt: formatNumber(summary.prompt_tokens, i18n.language),
            completion: formatNumber(summary.completion_tokens, i18n.language),
          })}
          icon={<RiArrowRightUpLine />}
        />
        <MetricCard
          label={t('logs.estimatedCost')}
          value={formatCurrency(summary.estimated_cost_usd, i18n.language)}
          hint={t('logs.savingsHint', {
            amount: formatCurrency(
              summary.estimated_savings_usd,
              i18n.language,
            ),
          })}
          icon={<RiCoinsLine />}
        />
        <MetricCard
          label={t('logs.streamingRatio')}
          value={`${streamRatio}%`}
          hint={t('logs.streamRequestsHint', {
            count: formatNumber(summary.stream_requests, i18n.language),
          })}
          icon={<RiArrowRightUpLine />}
        />
      </div>

      <Panel>
        <div className="flex items-center justify-between gap-4">
          <div>
            <h2 className="text-sm font-semibold text-foreground">
              {t('logs.captureBodiesTitle')}
            </h2>
            <p className="mt-1 text-sm text-muted-foreground">
              {t('logs.captureBodiesDesc')}
            </p>
          </div>
          <Switch
            checked={settings.capture_bodies}
            disabled={settingsMutation.isPending}
            onCheckedChange={toggleCaptureBodies}
          />
        </div>
      </Panel>

      {!hasTraffic ? (
        <EmptyState
          title={t('logs.emptyTitle')}
          description={t('logs.emptyDescription')}
        />
      ) : (
        <>
          <Panel>
            <h2 className="text-sm font-semibold text-foreground">
              {t('logs.tableTitle')}
            </h2>
            <div className="mt-4 overflow-x-auto rounded-lg border border-border">
              <table className="w-full min-w-[1100px] text-left text-sm">
                <thead className="bg-muted text-muted-foreground">
                  <tr>
                    <th className="px-3 py-3 font-medium">
                      <ColumnHeaderWithInfo
                        label={t('logs.columns.timestamp')}
                        description={t('logs.columnsHelp.timestamp')}
                      />
                    </th>
                    <th className="px-3 py-3 font-medium">
                      <ColumnHeaderWithInfo
                        label={t('logs.columns.endpoint')}
                        description={t('logs.columnsHelp.endpoint')}
                      />
                    </th>
                    <th className="px-3 py-3 font-medium">
                      <ColumnHeaderWithInfo
                        label={t('logs.columns.providerModel')}
                        description={t('logs.columnsHelp.providerModel')}
                      />
                    </th>
                    <th className="px-3 py-3 font-medium">
                      <ColumnHeaderWithInfo
                        label={t('logs.columns.app')}
                        description={t('logs.columnsHelp.app')}
                      />
                    </th>
                    <th className="px-3 py-3 font-medium">
                      <ColumnHeaderWithInfo
                        label={t('logs.columns.tokens')}
                        description={t('logs.columnsHelp.tokens')}
                      />
                    </th>
                    <th className="px-3 py-3 font-medium">
                      <ColumnHeaderWithInfo
                        label={t('logs.columns.cost')}
                        description={t('logs.columnsHelp.cost')}
                      />
                    </th>
                    <th className="px-3 py-3 font-medium">
                      <ColumnHeaderWithInfo
                        label={t('logs.columns.speed')}
                        description={t('logs.columnsHelp.speed')}
                      />
                    </th>
                    <th className="px-3 py-3 font-medium">
                      <ColumnHeaderWithInfo
                        label={t('logs.columns.finish')}
                        description={t('logs.columnsHelp.finish')}
                      />
                    </th>
                    <th className="px-3 py-3 text-right font-medium">
                      <span className="sr-only">
                        {t('logs.columns.actions')}
                      </span>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {latestEntries.map((entry) => {
                    const speed =
                      entry.duration_ms > 0 && entry.total_tokens > 0
                        ? Math.round(
                            (entry.total_tokens / entry.duration_ms) * 1000,
                          )
                        : null;
                    const providerModel = displayProviderModel(entry);
                    return (
                      <tr
                        key={`${entry.request_id}-${entry.timestamp}`}
                        className="border-t border-border"
                      >
                        <td className="px-3 py-3 text-muted-foreground">
                          {new Date(entry.timestamp).toLocaleString(
                            i18n.language,
                          )}
                        </td>
                        <td className="px-3 py-3">
                          <div className="flex items-center gap-2">
                            <Badge variant="outline">
                              {displayRequestMethod(entry)}
                            </Badge>
                            <span className="font-mono text-xs text-foreground">
                              {entry.endpoint || '—'}
                            </span>
                          </div>
                        </td>
                        <td className="px-3 py-3">
                          <div className="space-y-1">
                            <div className="font-mono text-xs font-medium text-foreground">
                              {providerModel.primary}
                            </div>
                            {providerModel.mappedFrom ? (
                              <div className="text-xs text-muted-foreground">
                                {providerModel.mappedFrom} →{' '}
                                {providerModel.primary}
                              </div>
                            ) : null}
                          </div>
                        </td>
                        <td className="px-3 py-3 text-muted-foreground">
                          {formatAppLabel(entry.app)}
                        </td>
                        <td className="px-3 py-3 text-xs text-muted-foreground">
                          <div className="space-y-1">
                            <div>
                              <span className="font-medium text-foreground">
                                {t('logs.tokenLabels.input')}:
                              </span>{' '}
                              <span className="font-mono">
                                {formatNumber(
                                  entry.prompt_tokens,
                                  i18n.language,
                                )}
                              </span>
                            </div>
                            <div>
                              <span className="font-medium text-foreground">
                                {t('logs.tokenLabels.output')}:
                              </span>{' '}
                              <span className="font-mono">
                                {formatNumber(
                                  entry.completion_tokens,
                                  i18n.language,
                                )}
                              </span>
                            </div>
                            <div>
                              <span className="font-medium text-foreground">
                                {t('logs.tokenLabels.cache')}:
                              </span>{' '}
                              <span className="font-mono">
                                {formatNumber(
                                  toNumber(entry.cache_tokens),
                                  i18n.language,
                                )}
                              </span>
                            </div>
                          </div>
                        </td>
                        <td className="px-3 py-3 text-muted-foreground">
                          {formatCurrency(
                            entry.estimated_cost_usd,
                            i18n.language,
                          )}
                        </td>
                        <td className="px-3 py-3 text-muted-foreground">
                          {speed === null ? '—' : `${speed} tok/s`}
                        </td>
                        <td className="px-3 py-3 text-muted-foreground">
                          {entry.finish_reason?.trim() || '—'}
                        </td>
                        <td className="px-3 py-3 text-right">
                          <div className="flex items-center justify-end gap-2">
                            {isUpstreamValidationError(entry) ? (
                              <Badge variant="destructive">
                                {t('logs.badges.upstreamValidationError')}
                              </Badge>
                            ) : null}
                            <Button
                              size="sm"
                              variant="outline"
                              onClick={() => setSelectedEntry(entry)}
                            >
                              <RiEyeLine className="size-4" />
                              {t('logs.viewDetails')}
                            </Button>
                          </div>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            {hasMore ? (
              <div className="mt-4 flex justify-center">
                <Button
                  variant="outline"
                  onClick={loadMore}
                  disabled={listQuery.isFetching}
                >
                  {t('logs.loadMore')}
                </Button>
              </div>
            ) : null}
          </Panel>

          <Sheet
            open={selectedEntry !== null}
            onOpenChange={(open) => {
              if (!open) {
                setSelectedEntry(null);
              }
            }}
          >
            <SheetContent
              side="right"
              className="data-[side=right]:w-[90vw] data-[side=right]:sm:max-w-[42rem] data-[side=right]:lg:max-w-[56rem] data-[side=right]:xl:max-w-[64rem]"
            >
              {selectedEntry ? (
                <>
                  <SheetHeader>
                    <SheetTitle>{t('logs.detailsTitle')}</SheetTitle>
                    <SheetDescription>
                      {selectedEntry.request_id}
                    </SheetDescription>
                  </SheetHeader>
                  <div className="px-6 pb-6">
                    <Tabs defaultValue="overview">
                      <TabsList>
                        <TabsTrigger value="overview">
                          {t('logs.details.overview')}
                        </TabsTrigger>
                        <TabsTrigger value="request">
                          {t('logs.details.request')}
                        </TabsTrigger>
                        <TabsTrigger value="response">
                          {t('logs.details.response')}
                        </TabsTrigger>
                        <TabsTrigger value="error">
                          {t('logs.details.error')}
                        </TabsTrigger>
                      </TabsList>

                      <TabsContent value="overview" className="mt-4 space-y-2">
                        <DetailRow
                          label="Requested model"
                          value={selectedEntry.requested_model || '—'}
                        />
                        <DetailRow
                          label="Provider"
                          value={selectedEntry.provider}
                        />
                        <DetailRow label="Model" value={selectedEntry.model} />
                        <DetailRow
                          label="Routing"
                          value={`${displayProviderModel(selectedEntry).mappedFrom || selectedEntry.requested_model || selectedEntry.model} -> ${displayProviderModel(selectedEntry).primary}`}
                        />
                        <DetailRow
                          label="Endpoint"
                          value={selectedEntry.endpoint}
                        />
                        <DetailRow
                          label="Timestamp"
                          value={new Date(
                            selectedEntry.timestamp,
                          ).toLocaleString(i18n.language)}
                        />
                        <DetailRow
                          label="Status"
                          value={String(selectedEntry.status_code)}
                        />
                        <DetailRow
                          label="Duration"
                          value={`${selectedEntry.duration_ms} ms`}
                        />
                        <DetailRow
                          label="Finish"
                          value={selectedEntry.finish_reason || '—'}
                        />
                      </TabsContent>

                      <TabsContent value="request" className="mt-4 space-y-3">
                        {selectedEntry.request_body ? (
                          <>
                            <CopyButton
                              value={selectedEntry.request_body}
                              size="sm"
                              variant="outline"
                            >
                              {t('logs.copy')}
                            </CopyButton>
                            <pre className="max-h-[380px] overflow-auto rounded-lg border border-border bg-muted/40 p-3 text-xs leading-5 text-foreground">
                              {selectedEntry.request_body}
                            </pre>
                          </>
                        ) : (
                          <div className="rounded-lg border border-dashed border-border p-4 text-sm text-muted-foreground">
                            <RiCodeLine className="mr-2 inline size-4" />
                            {t('logs.noRequestBody')}
                          </div>
                        )}
                      </TabsContent>

                      <TabsContent value="response" className="mt-4 space-y-3">
                        {selectedEntry.response_body ? (
                          <>
                            <CopyButton
                              value={selectedEntry.response_body}
                              size="sm"
                              variant="outline"
                            >
                              {t('logs.copy')}
                            </CopyButton>
                            <pre className="max-h-[380px] overflow-auto rounded-lg border border-border bg-muted/40 p-3 text-xs leading-5 text-foreground">
                              {selectedEntry.response_body}
                            </pre>
                          </>
                        ) : (
                          <div className="rounded-lg border border-dashed border-border p-4 text-sm text-muted-foreground">
                            <RiCodeLine className="mr-2 inline size-4" />
                            {t('logs.noResponseBody')}
                          </div>
                        )}
                      </TabsContent>

                      <TabsContent value="error" className="mt-4 space-y-3">
                        {selectedEntry.error ? (
                          <>
                            <CopyButton
                              value={selectedEntry.error}
                              size="sm"
                              variant="outline"
                            >
                              {t('logs.copy')}
                            </CopyButton>
                            <pre className="max-h-[380px] overflow-auto rounded-lg border border-border bg-danger/5 p-3 text-xs leading-5 text-foreground">
                              {selectedEntry.error}
                            </pre>
                          </>
                        ) : (
                          <div className="rounded-lg border border-dashed border-border p-4 text-sm text-muted-foreground">
                            <RiErrorWarningLine className="mr-2 inline size-4" />
                            {t('logs.noErrorData')}
                          </div>
                        )}
                      </TabsContent>
                    </Tabs>
                  </div>
                </>
              ) : null}
            </SheetContent>
          </Sheet>
        </>
      )}
    </div>
  );
}

function DetailRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="grid grid-cols-[120px_1fr] gap-3 rounded-lg border border-border bg-muted/30 px-3 py-2 text-sm">
      <p className="font-medium text-muted-foreground">{label}</p>
      <p className="text-foreground">{value}</p>
    </div>
  );
}

function ColumnHeaderWithInfo({
  label,
  description,
}: {
  label: string;
  description: string;
}) {
  return (
    <div className="inline-flex items-center gap-1.5">
      <span>{label}</span>
      <Tooltip>
        <TooltipTrigger
          aria-label={label}
          className="rounded-sm text-muted-foreground outline-none transition hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring"
        >
          <RiInformationLine className="size-3.5" />
        </TooltipTrigger>
        <TooltipContent className="max-w-72 text-left">
          {description}
        </TooltipContent>
      </Tooltip>
    </div>
  );
}
