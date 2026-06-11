import { Badge } from '@quotio/ui/components/badge';
import { Button } from '@quotio/ui/components/button';
import { cn } from '@quotio/ui/lib/utils';
import {
  RiArrowLeftRightLine,
  RiErrorWarningLine,
  RiRefreshLine,
} from '@remixicon/react';
import { ProviderIcon } from '@/components/admin/provider-icon';
import type {
  QuotaAccountView,
  QuotaDisplayMode,
  QuotaDisplayStyle,
  QuotaModelView,
} from '../types';
import { formatTimeAgo } from '../utils';
import { MetricGroup } from './metric-presenters';

type AntigravityGroup = {
  name: string;
  models: QuotaModelView[];
  aggregatePercent: number | null;
  resetTime?: string;
};

const ANTIGRAVITY_GROUP_ORDER = [
  'Gemini 3 Pro',
  'Gemini 3 Flash',
  'Claude',
] as const;

function getAntigravityGroupName(modelName: string) {
  const lower = modelName.toLowerCase();
  if (
    lower.includes('claude') ||
    lower.includes('gpt') ||
    lower.includes('oss')
  ) {
    return 'Claude';
  }
  if (lower.includes('gemini') && lower.includes('pro')) {
    return 'Gemini 3 Pro';
  }
  if (lower.includes('gemini') && lower.includes('flash')) {
    return 'Gemini 3 Flash';
  }
  return null;
}

function parseModelPercent(value?: number) {
  return typeof value === 'number' && !Number.isNaN(value) && value >= 0
    ? value
    : null;
}

function getAntigravityGroupedModels(models: QuotaModelView[]) {
  const groups = new Map<string, QuotaModelView[]>();
  models.forEach((model) => {
    const group = getAntigravityGroupName(model.name);
    if (!group) return;
    const bucket = groups.get(group) ?? [];
    bucket.push(model);
    groups.set(group, bucket);
  });

  const grouped: AntigravityGroup[] = ANTIGRAVITY_GROUP_ORDER.filter(
    (groupName) => groups.has(groupName),
  )
    .flatMap((groupName) => {
      const items = groups.get(groupName) ?? [];
      if (items.length === 0) return [];

      const remainingValues = items
        .map((item) => parseModelPercent(item.remaining_percent))
        .filter((value): value is number => value !== null);

      const usedValues = items
        .map((item) => {
          const usedPercent = parseModelPercent(item.used_percent);
          if (usedPercent !== null) {
            return usedPercent;
          }
          if (item.remaining_percent == null) {
            return null;
          }
          return 100 - item.remaining_percent;
        })
        .filter((value): value is number => value !== null);

      const resetValues = items
        .map((item) =>
          item.reset_time
            ? new Date(item.reset_time).getTime()
            : Number.POSITIVE_INFINITY,
        )
        .filter((value) => Number.isFinite(value));

      const resetTime =
        resetValues.length > 0
          ? new Date(Math.min(...resetValues)).toISOString()
          : undefined;

      return [
        {
          name: groupName,
          models: items,
          aggregatePercent:
            remainingValues.length > 0
              ? Math.min(...remainingValues)
              : usedValues.length > 0
                ? 100 - Math.min(...usedValues)
                : null,
          resetTime,
        },
      ];
    })
    .sort(
      (left, right) =>
        (left.aggregatePercent ?? Number.POSITIVE_INFINITY) -
        (right.aggregatePercent ?? Number.POSITIVE_INFINITY),
    );

  return grouped;
}

function metricLabelPercent(value: number | null, mode: QuotaDisplayMode) {
  if (value == null) return '—';
  const displayed = mode === 'used' ? 100 - value : value;
  return `${Math.round(displayed)}%`;
}

function metricBarClass(percent: number | null, mode: QuotaDisplayMode) {
  const value = percent == null ? 0 : mode === 'used' ? 100 - percent : percent;
  if (value > 50) return 'bg-emerald-500/15 dark:bg-emerald-400/20';
  if (value > 20) return 'bg-amber-500/15 dark:bg-amber-400/20';
  return 'bg-rose-500/15 dark:bg-rose-400/20';
}

function metricFillClass(percent: number | null, mode: QuotaDisplayMode) {
  const value = percent == null ? 0 : mode === 'used' ? 100 - percent : percent;
  if (value > 50) return 'bg-emerald-500 dark:bg-emerald-400';
  if (value > 20) return 'bg-amber-500 dark:bg-amber-400';
  return 'bg-rose-500 dark:bg-rose-400';
}

function metricToneClass(percent: number | null, mode: QuotaDisplayMode) {
  const value = percent == null ? 0 : mode === 'used' ? 100 - percent : percent;
  if (value > 50) return 'text-emerald-500 dark:text-emerald-400';
  if (value > 20) return 'text-amber-500 dark:text-amber-400';
  return 'text-rose-500 dark:text-rose-400';
}

type Props = {
  account: QuotaAccountView;
  displayMode: QuotaDisplayMode;
  displayStyle: QuotaDisplayStyle;
  now: number;
  onRefresh: () => void;
  onSwitchAccount?: () => void;
  isRefreshing: boolean;
  isSwitching: boolean;
};

export function AccountCard({
  account,
  displayMode,
  displayStyle,
  now,
  onRefresh,
  onSwitchAccount,
  isRefreshing,
  isSwitching,
}: Props) {
  const sortedModels = [...account.models].sort((left, right) => {
    const leftValue = left.remaining_percent ?? Number.POSITIVE_INFINITY;
    const rightValue = right.remaining_percent ?? Number.POSITIVE_INFINITY;
    return leftValue - rightValue;
  });

  const isAntigravity = account.provider === 'antigravity';
  const groupedModels = isAntigravity
    ? getAntigravityGroupedModels(account.models)
    : [];

  return (
    <div className="rounded-lg border border-border/70 bg-card p-4">
      <div className="flex items-center justify-between gap-2">
        <div className="flex min-w-0 items-center gap-2.5">
          <div className="flex h-5 w-5 shrink-0 items-center justify-center rounded-md border border-border bg-muted">
            <ProviderIcon provider={account.provider} className="h-3.5 w-3.5" />
          </div>
          {account.plan_display_name ? (
            <Badge
              variant="secondary"
              className="px-1.5 py-0 text-[10px] font-normal uppercase tracking-wider"
            >
              {account.plan_display_name}
            </Badge>
          ) : null}
          <div className="min-w-0">
            <p className="truncate text-sm font-medium text-foreground">
              {account.account_key}
            </p>
          </div>
        </div>
        <div className="flex flex-wrap items-center justify-end gap-2">
          {account.is_active ? (
            <Badge className="bg-emerald-500/10 text-emerald-600 dark:text-emerald-400">
              Active
            </Badge>
          ) : null}
          {account.is_forbidden ? (
            <Badge variant="destructive">
              <RiErrorWarningLine className="mr-1 h-3.5 w-3.5" />
              Forbidden
            </Badge>
          ) : null}

          {account.quota_supported ? (
            <Button
              size="sm"
              variant="ghost"
              className="h-7 px-2 text-xs text-muted-foreground hover:text-foreground"
              onClick={onRefresh}
              disabled={isRefreshing}
            >
              <RiRefreshLine
                className={`mr-1 h-3 w-3 ${isRefreshing ? 'animate-spin' : ''}`}
              />
              Refresh
            </Button>
          ) : null}
          {onSwitchAccount ? (
            <Button
              size="sm"
              variant="ghost"
              className="h-7 px-2 text-xs text-muted-foreground hover:text-foreground"
              onClick={onSwitchAccount}
              disabled={isSwitching}
            >
              <RiArrowLeftRightLine
                className={`mr-1 h-3 w-3 ${isSwitching ? 'animate-spin' : ''}`}
              />
              Switch
            </Button>
          ) : null}
        </div>
      </div>

      {!account.quota_supported ? (
        <div className="mt-3 rounded-lg border border-border/70 bg-muted/40 p-2.5 text-xs text-muted-foreground">
          {account.quota_status_reason ??
            'Quota is not supported for this provider.'}
        </div>
      ) : null}

      {account.quota_status === 'error' && account.error ? (
        <div className="mt-3 rounded-lg border border-rose-500/20 bg-rose-500/10 p-2.5 text-xs text-rose-600 dark:text-rose-300">
          {account.error}
        </div>
      ) : null}

      <div className="mt-4">
        {isAntigravity && groupedModels.length > 0 ? (
          <div className="space-y-4">
            {groupedModels.map((group) => (
              <details
                key={`${account.credential_id}:${group.name}`}
                className="rounded-lg border border-border/50 bg-muted/30 px-3 py-2 text-sm"
              >
                <summary className="list-none cursor-pointer text-sm font-semibold">
                  <div className="flex items-center justify-between gap-2">
                    <span>{group.name}</span>
                    <span
                      className={cn(
                        'font-medium',
                        metricToneClass(group.aggregatePercent, displayMode),
                      )}
                    >
                      {metricLabelPercent(group.aggregatePercent, displayMode)}
                      {group.resetTime ? (
                        <span className="ml-1.5 text-[11px] text-muted-foreground">
                          {formatTimeAgo(group.resetTime, now)}
                        </span>
                      ) : null}
                    </span>
                  </div>

                  <div className="mt-2 overflow-hidden rounded-full bg-muted">
                    <div
                      className={cn(
                        'h-2 w-full rounded-full bg-opacity-30 transition-[width] duration-300',
                        metricBarClass(group.aggregatePercent, displayMode),
                      )}
                    >
                      <div
                        className={cn(
                          'h-full rounded-full transition-[width] duration-300',
                          metricFillClass(group.aggregatePercent, displayMode),
                        )}
                        style={{
                          width: `${group.aggregatePercent == null ? 0 : Math.max(0, Math.min(100, group.aggregatePercent))}%`,
                        }}
                      />
                    </div>
                  </div>
                </summary>
                <div className="mt-3 space-y-2 border-t border-border/60 pt-2">
                  {group.models.map((model) => (
                    <div
                      key={model.name}
                      className="flex items-center justify-between text-xs"
                    >
                      <span className="text-muted-foreground">
                        {model.display_name}
                      </span>
                      <span
                        className={cn(
                          'font-medium',
                          metricToneClass(
                            model.remaining_percent ?? null,
                            displayMode,
                          ),
                        )}
                      >
                        {metricLabelPercent(
                          model.remaining_percent ?? null,
                          displayMode,
                        )}
                      </span>
                    </div>
                  ))}
                </div>
              </details>
            ))}
          </div>
        ) : sortedModels.length > 0 ? (
          <MetricGroup
            models={sortedModels}
            mode={displayMode}
            style={displayStyle}
          />
        ) : account.quota_supported ? (
          <div className="rounded-lg border border-dashed border-border/70 p-3 text-xs text-muted-foreground">
            No quota metrics available for this account yet.
          </div>
        ) : null}
      </div>

      {account.last_updated ? (
        <div className="mt-3 border-t border-border/50 pt-2.5 text-[11px] text-muted-foreground">
          Updated {formatTimeAgo(account.last_updated, now)}
        </div>
      ) : null}
    </div>
  );
}
