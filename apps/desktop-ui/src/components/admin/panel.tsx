import { cn } from '@quotio/ui/lib/utils';
import type { ComponentProps } from 'react';

export function Panel({ className, ...props }: ComponentProps<'section'>) {
  return (
    <section
      className={cn(
        'rounded-xl border border-border bg-card p-5 shadow-sm',
        className,
      )}
      {...props}
    />
  );
}
