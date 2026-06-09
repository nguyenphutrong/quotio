import { Separator } from '@quotio/ui/components/separator';
import {
  SidebarInset,
  SidebarProvider,
  SidebarTrigger,
} from '@quotio/ui/components/sidebar';
import { Outlet } from '@tanstack/react-router';
import { lazy, Suspense } from 'react';
import { AppSidebar } from '@/components/app-sidebar';
import { GatewayUrlBadge } from '@/components/layouts/gateway-url-badge';

const CommandPalette = lazy(() =>
  import('@/components/navigation/command-palette').then((mod) => ({
    default: mod.CommandPalette,
  })),
);

export function DashboardLayout() {
  return (
    <SidebarProvider className="h-svh overflow-hidden">
      <AppSidebar />
      <SidebarInset className="overflow-hidden">
        <header className="flex h-14 shrink-0 items-center gap-2 border-b border-border/60 bg-background px-4 transition-[width,height] ease-linear group-has-[[data-collapsible=icon]]/sidebar-wrapper:h-12">
          <SidebarTrigger className="-ml-1" />
          <Separator orientation="vertical" className="mr-1 h-4" />
          <GatewayUrlBadge />
        </header>

        <div className="flex flex-1 flex-col gap-4 overflow-y-auto p-4">
          <Outlet />
        </div>

        <Suspense fallback={null}>
          <CommandPalette />
        </Suspense>
      </SidebarInset>
    </SidebarProvider>
  );
}
