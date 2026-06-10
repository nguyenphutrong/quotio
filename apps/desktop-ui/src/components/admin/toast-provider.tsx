import { Button } from '@quotio/ui/components/button';
import { RiCheckLine, RiCloseLine, RiErrorWarningLine } from '@remixicon/react';
import {
  createContext,
  type ReactNode,
  useCallback,
  useContext,
  useMemo,
  useState,
} from 'react';
import { useAdminRuntime } from '@/lib/admin/runtime';

type ToastTone = 'success' | 'error';

type ToastRecord = {
  id: string;
  title: string;
  tone: ToastTone;
};

type ToastContextValue = {
  success: (title: string) => void;
  error: (title: string) => void;
};

const ToastContext = createContext<ToastContextValue | null>(null);

function ToastViewport({
  toasts,
  dismiss,
}: {
  toasts: ToastRecord[];
  dismiss: (id: string) => void;
}) {
  if (toasts.length === 0) {
    return null;
  }

  return (
    <div className="pointer-events-none fixed inset-x-0 top-4 z-50 flex flex-col items-center gap-2 px-4">
      {toasts.map((toast) => (
        <div
          key={toast.id}
          className="pointer-events-auto flex w-full max-w-md items-center gap-3 rounded-2xl border border-border bg-background/95 px-4 py-3 shadow-lg backdrop-blur"
        >
          <div
            className={
              toast.tone === 'success' ? 'text-emerald-600' : 'text-destructive'
            }
          >
            {toast.tone === 'success' ? (
              <RiCheckLine />
            ) : (
              <RiErrorWarningLine />
            )}
          </div>
          <p className="flex-1 text-sm font-medium text-foreground">
            {toast.title}
          </p>
          <Button
            variant="ghost"
            size="icon-xs"
            onClick={() => dismiss(toast.id)}
            title="Dismiss"
          >
            <RiCloseLine />
          </Button>
        </div>
      ))}
    </div>
  );
}

export function ToastProvider({ children }: { children: ReactNode }) {
  const { notify } = useAdminRuntime();
  const [toasts, setToasts] = useState<ToastRecord[]>([]);

  const dismiss = useCallback((id: string) => {
    setToasts((current) => current.filter((toast) => toast.id !== id));
  }, []);

  const push = useCallback(
    async (title: string, tone: ToastTone) => {
      try {
        const delivered = await notify({
          title: 'Quotio',
          message: title,
          tone,
        });

        if (delivered) {
          return;
        }
      } catch {
        // Fall back to the in-window toast for browser previews or denied OS notifications.
      }

      const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
      setToasts((current) => [...current, { id, title, tone }]);
      window.setTimeout(() => dismiss(id), 2400);
    },
    [dismiss, notify],
  );

  const value = useMemo<ToastContextValue>(
    () => ({
      success: (title: string) => void push(title, 'success'),
      error: (title: string) => void push(title, 'error'),
    }),
    [push],
  );

  return (
    <ToastContext.Provider value={value}>
      {children}
      <ToastViewport toasts={toasts} dismiss={dismiss} />
    </ToastContext.Provider>
  );
}

export function useToast() {
  const context = useContext(ToastContext);
  if (!context) {
    throw new Error('useToast must be used within ToastProvider');
  }
  return context;
}
