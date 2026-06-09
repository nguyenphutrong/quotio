import { cn } from '@quotio/ui/lib/utils';

const toneClasses = {
  neutral: 'border-border bg-muted text-muted-foreground',
  success: 'border-success/20 bg-success/10 text-success',
  warning: 'border-warning/20 bg-warning/10 text-warning',
  danger: 'border-danger/20 bg-danger/10 text-danger',
} as const;

export function StatusBadge({
  children,
  tone = 'neutral',
}: {
  children: string;
  tone?: keyof typeof toneClasses;
}) {
  return (
    <span
      className={cn(
        'inline-flex items-center rounded-md border px-2 py-0.5 text-xs font-medium capitalize',
        toneClasses[tone],
      )}
    >
      {children}
    </span>
  );
}
