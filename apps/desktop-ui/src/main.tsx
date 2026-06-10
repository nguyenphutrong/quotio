import { QueryClientProvider } from '@tanstack/react-query';
import { createRouter, RouterProvider } from '@tanstack/react-router';
import { NuqsAdapter } from 'nuqs/adapters/tanstack-router';
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';

import '@quotio/ui/globals.css';
import { ToastProvider } from '@/components/admin/toast-provider';
import i18n from '@/i18n';
import { getDesktopBootstrap } from '@/lib/admin/bootstrap';
import { createAdminQueryClient } from '@/lib/admin/query';
import { AdminRuntimeProvider } from '@/lib/admin/runtime';
import { routeTree } from './routeTree.gen';

const rootElement = document.getElementById('root');

if (!rootElement) {
  throw new Error('Root element not found');
}

const root = createRoot(rootElement);

function renderFatalError(message: string) {
  root.render(
    <StrictMode>
      <div className="flex min-h-screen items-center justify-center bg-background p-6 text-foreground">
        <div className="max-w-lg rounded-lg border border-border bg-card/80 p-6">
          <p className="text-sm font-medium text-destructive">
            {i18n.t('bootstrap.failedLabel')}
          </p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight">
            {i18n.t('bootstrap.failedTitle')}
          </h1>
          <p className="mt-3 text-sm leading-6 text-muted-foreground">
            {message}
          </p>
        </div>
      </div>
    </StrictMode>,
  );
}

async function start() {
  try {
    const bootstrap = getDesktopBootstrap();
    const queryClient = createAdminQueryClient();
    const router = createRouter({
      routeTree,
      basepath: bootstrap.basePath,
      scrollRestoration: true,
      scrollToTopSelectors: ['[data-scroll-restoration-id="dashboard-main"]'],
      context: {
        queryClient,
      },
    });

    root.render(
      <StrictMode>
        <QueryClientProvider client={queryClient}>
          <AdminRuntimeProvider bootstrap={bootstrap}>
            <ToastProvider>
              <NuqsAdapter>
                <RouterProvider router={router} />
              </NuqsAdapter>
            </ToastProvider>
          </AdminRuntimeProvider>
        </QueryClientProvider>
      </StrictMode>,
    );
  } catch (error) {
    const message =
      error instanceof Error ? error.message : i18n.t('bootstrap.unknownError');
    renderFatalError(message);
  }
}

void start();
