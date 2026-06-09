import { Badge } from '@quotio/ui/components/badge';
import { Button } from '@quotio/ui/components/button';
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
} from '../types';
import { formatTimeAgo } from '../utils';
import { MetricGroup } from './metric-presenters';

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

  return (
    <div className="rounded-xl border border-border/70 bg-card p-4 shadow-sm">
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
        {sortedModels.length > 0 ? (
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
