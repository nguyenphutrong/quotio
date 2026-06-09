import { TooltipProvider } from '@quotio/ui/components/tooltip';
import { createRootRoute } from '@tanstack/react-router';
import { DashboardLayout } from '@/components/layouts/dashboard-layout';
import { ThemeProvider } from '@/components/theme-provider.tsx';
import { useAdminRuntime } from '@/lib/admin/runtime';

export const Route = createRootRoute({
  component: RootLayout,
});

function RootLayout() {
  const { bootstrap } = useAdminRuntime();

  return (
    <ThemeProvider defaultTheme={bootstrap.appearance}>
      <TooltipProvider>
        <DashboardLayout />
      </TooltipProvider>
    </ThemeProvider>
  );
}
