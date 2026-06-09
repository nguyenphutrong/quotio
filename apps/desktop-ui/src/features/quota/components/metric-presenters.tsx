import { cn } from '@quotio/ui/lib/utils';
import type {
  QuotaDisplayMode,
  QuotaDisplayStyle,
  QuotaModelView,
} from '../types';
import { formatRelativeTime, formatTokenishValue, formatUSD } from '../utils';

function displayPercent(model: QuotaModelView, mode: QuotaDisplayMode) {
  if (mode === 'used') {
    return model.used_percent ?? null;
  }
  return model.remaining_percent ?? null;
}

function statusScore(percent: number | null, mode: QuotaDisplayMode) {
  if (percent == null) return null;
  return mode === 'used' ? 100 - percent : percent;
}

function statusTone(percent: number | null, mode: QuotaDisplayMode) {
  const score = statusScore(percent, mode);
  if (score == null) return 'text-muted-foreground';
  if (score > 50) return 'text-emerald-500 dark:text-emerald-400';
  if (score > 20) return 'text-amber-500 dark:text-amber-400';
  return 'text-rose-500 dark:text-rose-400';
}

function statusFill(percent: number | null, mode: QuotaDisplayMode) {
  const score = statusScore(percent, mode);
  if (score == null) return 'bg-muted';
  if (score > 50) return 'bg-emerald-500 dark:bg-emerald-400';
  if (score > 20) return 'bg-amber-500 dark:bg-amber-400';
  return 'bg-rose-500 dark:bg-rose-400';
}

function statusFillMuted(percent: number | null, mode: QuotaDisplayMode) {
  const score = statusScore(percent, mode);
  if (score == null) return 'bg-muted';
  if (score > 50) return 'bg-emerald-500/15 dark:bg-emerald-400/20';
  if (score > 20) return 'bg-amber-500/15 dark:bg-amber-400/20';
  return 'bg-rose-500/15 dark:bg-rose-400/20';
}

function metricSummary(model: QuotaModelView, mode: QuotaDisplayMode) {
  if (
    model.quota_kind === 'absolute-credits' ||
    model.quota_kind === 'replenishing-balance'
  ) {
    const current =
      mode === 'used'
        ? (model.used ?? model.used_percent)
        : (model.remaining ?? model.remaining_value ?? model.remaining_percent);
    const total = model.limit ?? model.limit_value ?? model.cap_value;
    if (current == null && total == null) {
      if (
        model.quota_kind === 'replenishing-balance' &&
        model.replenish_rate_per_hour != null
      ) {
        return `+${formatValue(
          model.replenish_rate_per_hour,
          model.display_unit,
        )}/h`;
      }
      return null;
    }
    const summary = `${formatValue(current, model.display_unit)} / ${formatValue(
      total,
      model.display_unit,
    )}`;
    if (
      model.quota_kind === 'replenishing-balance' &&
      model.replenish_rate_per_hour != null
    ) {
      return `${summary} (+${formatValue(
        model.replenish_rate_per_hour,
        model.display_unit,
      )}/h)`;
    }
    return summary;
  }
  const percent = displayPercent(model, mode);
  return percent == null ? null : `${Math.round(percent)}%`;
}

function formatValue(value: number | undefined | null, unit?: string) {
  if (value == null) return '—';
  switch (unit) {
    case 'usd':
      return formatUSD(value);
    case 'tokens':
      return formatTokenishValue(value);
    case 'count':
    case 'credits':
      return new Intl.NumberFormat().format(Math.round(value));
    default:
      return `${Math.round(value)}`;
  }
}

export function MetricProgressBar({
  model,
  mode,
  height = 'h-2',
}: {
  model: QuotaModelView;
  mode: QuotaDisplayMode;
  height?: string;
}) {
  const percent = displayPercent(model, mode);
  const clamped = percent == null ? 0 : Math.max(0, Math.min(100, percent));

  return (
    <div
      className={cn(
        'relative overflow-hidden rounded-full',
        height,
        statusFillMuted(percent, mode),
      )}
    >
      <div
        className={cn(
          'absolute inset-y-0 left-0 rounded-full transition-[width] duration-300 ease-out',
          statusFill(percent, mode),
        )}
        style={{ width: `${clamped}%` }}
      />
    </div>
  );
}

export function MetricGroup({
  models,
  mode,
  style,
}: {
  models: QuotaModelView[];
  mode: QuotaDisplayMode;
  style: QuotaDisplayStyle;
}) {
  if (style === 'overview') {
    return (
      <div className="grid gap-2.5">
        {models.map((model) => (
          <div key={model.name}>
            <div className="flex items-center justify-between gap-2 mb-1">
              <span className="text-xs font-medium text-foreground">
                {model.display_name}
              </span>
              <span
                className={cn(
                  'text-xs font-medium tabular-nums',
                  statusTone(displayPercent(model, mode), mode),
                )}
              >
                {metricSummary(model, mode) ?? '—'}
                {model.reset_time && (
                  <span className="ml-1.5 text-[10px] font-normal text-muted-foreground">
                    {formatRelativeTime(model.reset_time)}
                  </span>
                )}
              </span>
            </div>
            <MetricProgressBar model={model} mode={mode} height="h-2" />
          </div>
        ))}
      </div>
    );
  }

  // Focus style
  const primaryModel = models[0];
  const secondaryModels = models.slice(1);

  return (
    <div>
      <div className="mb-3 border-b border-border/50 pb-2.5">
        <p className="text-[10px] font-bold tracking-[0.06em] uppercase text-muted-foreground">
          Usage
        </p>
      </div>
      <div className="space-y-3">
        {primaryModel && (
          <div className="rounded-xl bg-muted/40 p-3">
            <div className="flex items-center justify-between gap-2 mb-2">
              <span className="text-sm font-bold text-foreground">
                {primaryModel.display_name}
              </span>
              <span
                className={cn(
                  'text-sm font-bold tabular-nums',
                  statusTone(displayPercent(primaryModel, mode), mode),
                )}
              >
                {metricSummary(primaryModel, mode) ?? '—'}
              </span>
            </div>
            <MetricProgressBar
              model={primaryModel}
              mode={mode}
              height="h-2.5"
            />
            {primaryModel.reset_time && (
              <p className="mt-2 text-[11px] font-medium text-muted-foreground">
                {formatRelativeTime(primaryModel.reset_time)}
              </p>
            )}
          </div>
        )}

        {secondaryModels.length > 0 && (
          <div className="space-y-2.5 px-1 pt-1">
            {secondaryModels.map((model) => (
              <div
                key={model.name}
                className="flex items-center justify-between gap-2"
              >
                <span className="text-xs font-semibold text-muted-foreground">
                  {model.display_name}
                </span>
                <span
                  className={cn(
                    'text-xs font-bold tabular-nums',
                    statusTone(displayPercent(model, mode), mode),
                  )}
                >
                  {metricSummary(model, mode) ?? '—'}
                </span>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
