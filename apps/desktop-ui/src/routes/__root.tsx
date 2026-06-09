import { TooltipProvider } from '@quotio/ui/components/tooltip';
import { createRootRoute } from '@tanstack/react-router';
import { DashboardLayout } from '@/components/layouts/dashboard-layout';
import { ThemeProvider } from '@/components/theme-provider.tsx';

export const Route = createRootRoute({
  component: RootLayout,
});

function RootLayout() {
  return (
    <ThemeProvider>
      <TooltipProvider>
        <DashboardLayout />
      </TooltipProvider>
    </ThemeProvider>
  );
}
