import { Button } from '@quotio/ui/components/button';
import { RiCheckLine, RiFileCopyLine } from '@remixicon/react';
import type React from 'react';
import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useToast } from '@/components/admin/toast-provider';

export interface CopyButtonProps extends React.ComponentProps<typeof Button> {
  value: string;
  successMessage?: string;
  errorMessage?: string;
}

export function CopyButton({
  value,
  successMessage,
  errorMessage,
  children,
  onClick,
  ...props
}: CopyButtonProps) {
  const { t } = useTranslation();
  const toast = useToast();
  const [copied, setCopied] = useState(false);

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      if (successMessage) {
        toast.success(successMessage);
      }
      setTimeout(() => setCopied(false), 2000);
    } catch {
      toast.error(errorMessage ?? t('common.unknownError'));
    }
  };

  return (
    <Button
      {...props}
      onClick={(event) => {
        onClick?.(event);
        if (event.defaultPrevented) {
          return;
        }
        void handleCopy();
      }}
    >
      {copied ? (
        <RiCheckLine className="text-emerald-500" />
      ) : (
        <RiFileCopyLine />
      )}
      {children}
    </Button>
  );
}
