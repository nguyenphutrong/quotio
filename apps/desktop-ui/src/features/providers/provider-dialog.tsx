import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@quotio/ui/components/dialog';
import { useTranslation } from 'react-i18next';
import { ProviderFormPanel } from '@/features/providers/provider-form-panel';
import type {
  ProviderPayload,
  ProviderResponse,
} from '@/features/providers/types';

export function ProviderDialog({
  open,
  onOpenChange,
  mode,
  provider,
  validationPreview,
  busy,
  onValidate,
  onCreate,
  onUpdate,
  onOAuthCreated,
  initialProviderKey,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  mode: 'create' | 'edit';
  provider: ProviderResponse | null;
  validationPreview: ProviderResponse | null;
  busy: boolean;
  onValidate: (payload: ProviderPayload) => Promise<void>;
  onCreate: (payload: ProviderPayload) => Promise<void>;
  onUpdate: (input: {
    id: string;
    label: string;
    disabled: boolean;
    headers?: Record<string, string>;
  }) => Promise<void>;
  onOAuthCreated?: (provider: ProviderResponse) => Promise<void> | void;
  initialProviderKey?: string;
}) {
  const { t } = useTranslation();

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg lg:max-w-2xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {mode === 'create'
              ? t('providers.dialogs.createTitle')
              : t('providers.dialogs.editTitle')}
          </DialogTitle>
          <DialogDescription>
            {mode === 'create'
              ? t('providers.dialogs.createDescription')
              : t('providers.dialogs.editDescription')}
          </DialogDescription>
        </DialogHeader>
        <ProviderFormPanel
          mode={mode}
          provider={provider}
          validationPreview={validationPreview}
          busy={busy}
          onValidate={onValidate}
          onCreate={onCreate}
          onUpdate={onUpdate}
          onOAuthCreated={onOAuthCreated}
          hideHeader
          initialProviderKey={initialProviderKey}
        />
      </DialogContent>
    </Dialog>
  );
}
