import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@quotio/ui/components/dialog';
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
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg lg:max-w-2xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {mode === 'create' ? 'Add Provider' : 'Edit provider'}
          </DialogTitle>
          <DialogDescription>
            {mode === 'create'
              ? 'Validate the payload before saving it into the provider store.'
              : 'You can update label and disabled state. OpenCode Go also allows editing quota metadata.'}
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
