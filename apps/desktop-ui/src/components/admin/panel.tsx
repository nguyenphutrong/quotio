import { cn } from '@quotio/ui/lib/utils';
import type { ComponentProps } from 'react';
import { useIsNativeDesktopRuntime } from '@/lib/admin/runtime';

export function Panel({ className, ...props }: ComponentProps<'section'>) {
  const isNativeDesktop = useIsNativeDesktopRuntime();

  return (
    <section
      className={cn(
        'border border-border bg-card p-5',
        isNativeDesktop ? 'rounded-lg' : 'rounded-xl shadow-sm',
        className,
      )}
      {...props}
    />
  );
}
