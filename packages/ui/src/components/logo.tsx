import { cn } from '@quotio/ui/lib/utils';
import type * as React from 'react';

interface LogoProps extends React.ComponentProps<'div'> {
  size?: number;
  withWordmark?: boolean;
}

function Logo({
  className,
  size = 24,
  withWordmark = false,
  ...props
}: LogoProps) {
  return (
    <div
      data-slot="logo"
      className={cn('flex items-center gap-2', className)}
      {...props}
    >
      <span
        aria-hidden="true"
        className="flex items-center justify-center rounded-lg bg-primary text-primary-foreground"
        style={{ width: size, height: size }}
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth={2.2}
          strokeLinecap="round"
          strokeLinejoin="round"
          width={Math.round(size * 0.58)}
          height={Math.round(size * 0.58)}
          role="img"
          aria-label="Quotio logo"
        >
          <title>Quotio</title>
          <path d="M12 2 L20 7 V17 L12 22 L4 17 V7 Z" />
          <path d="M15 14 L19 18" />
        </svg>
      </span>
      {withWordmark ? (
        <span className="font-heading text-sm font-semibold tracking-tight">
          Quotio
        </span>
      ) : null}
    </div>
  );
}

export { Logo };
