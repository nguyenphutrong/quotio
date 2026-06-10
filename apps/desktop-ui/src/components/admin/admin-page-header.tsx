import type { ReactNode } from 'react';
import { useIsNativeDesktopRuntime } from '@/lib/admin/runtime';

export function AdminPageHeader({
  title,
  description,
  actions,
}: {
  title: string;
  description: string;
  actions?: ReactNode;
}) {
  const isNativeDesktop = useIsNativeDesktopRuntime();

  if (isNativeDesktop) {
    return actions ? <div className="flex justify-end">{actions}</div> : null;
  }

  return (
    <div className="flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight text-foreground">
          {title}
        </h1>
        <p className="mt-2 max-w-3xl text-sm leading-6 text-muted-foreground">
          {description}
        </p>
      </div>
      {actions ? <div className="shrink-0">{actions}</div> : null}
    </div>
  );
}
