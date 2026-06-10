import {
  SidebarInset,
  SidebarProvider,
  SidebarTrigger,
} from '@quotio/ui/components/sidebar';
import { Outlet } from '@tanstack/react-router';
import { lazy, Suspense } from 'react';
import { AppSidebar } from '@/components/app-sidebar';
import { useIsNativeDesktopRuntime } from '@/lib/admin/runtime';

const CommandPalette = lazy(() =>
  import('@/components/navigation/command-palette').then((mod) => ({
    default: mod.CommandPalette,
  })),
);

export function DashboardLayout() {
  const isNativeDesktop = useIsNativeDesktopRuntime();

  return (
    <SidebarProvider className="h-svh overflow-hidden">
      <AppSidebar />
      <SidebarInset className="overflow-hidden">
        {isNativeDesktop ? null : (
          <header className="flex h-12 shrink-0 items-center gap-2 border-b border-border/60 bg-background px-4 transition-[width,height] ease-linear">
            <SidebarTrigger className="-ml-1" />
          </header>
        )}

        <div
          className="flex flex-1 flex-col gap-4 overflow-y-auto p-4"
          data-scroll-restoration-id="dashboard-main"
        >
          <Outlet />
        </div>

        {isNativeDesktop ? null : (
          <Suspense fallback={null}>
            <CommandPalette />
          </Suspense>
        )}
      </SidebarInset>
    </SidebarProvider>
  );
}
