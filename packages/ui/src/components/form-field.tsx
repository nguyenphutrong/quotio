import { cn } from '@quotio/ui/lib/utils';
import type * as React from 'react';

function FormFieldLabel({
  className,
  children,
  ...props
}: React.ComponentProps<'label'>) {
  return (
    <label
      data-slot="form-field-label"
      className={cn(
        'text-sm font-medium leading-none peer-disabled:cursor-not-allowed peer-disabled:opacity-50',
        className,
      )}
      {...props}
    >
      {children}
    </label>
  );
}

function FormFieldDescription({
  className,
  ...props
}: React.ComponentProps<'p'>) {
  return (
    <p
      data-slot="form-field-description"
      className={cn('text-sm text-muted-foreground', className)}
      {...props}
    />
  );
}

function FormFieldError({
  className,
  children,
  ...props
}: React.ComponentProps<'p'>) {
  return (
    <p
      data-slot="form-field-error"
      className={cn('text-sm font-medium text-destructive', className)}
      {...props}
    >
      {children}
    </p>
  );
}

function FormFieldGroup({ className, ...props }: React.ComponentProps<'div'>) {
  return (
    <div
      data-slot="form-field-group"
      className={cn('flex flex-col gap-2', className)}
      {...props}
    />
  );
}

export { FormFieldDescription, FormFieldError, FormFieldGroup, FormFieldLabel };
