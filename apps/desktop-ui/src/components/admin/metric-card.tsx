import { cn } from '@quotio/ui/lib/utils';
import type { ReactNode } from 'react';
import { Panel } from '@/components/admin/panel';

export function MetricCard({
  label,
  value,
  hint,
  icon,
  tone = 'default',
}: {
  label: string;
  value: ReactNode;
  hint?: string;
  icon?: ReactNode;
  tone?: 'default' | 'success' | 'warning';
}) {
  return (
    <Panel className="flex min-h-32 flex-col justify-between gap-4">
      <div className="flex items-start justify-between gap-4">
        <p className="text-sm font-medium text-muted-foreground">{label}</p>
        {icon ? (
          <div className="rounded-lg border border-border bg-muted p-2 text-muted-foreground">
            {icon}
          </div>
        ) : null}
      </div>
      <div>
        <div
          className={cn(
            'font-mono text-2xl font-semibold tabular-nums tracking-tight text-foreground',
            tone === 'success' && 'text-success',
            tone === 'warning' && 'text-warning',
          )}
        >
          {value}
        </div>
        {hint ? (
          <p className="mt-1 text-xs text-muted-foreground">{hint}</p>
        ) : null}
      </div>
    </Panel>
  );
}
