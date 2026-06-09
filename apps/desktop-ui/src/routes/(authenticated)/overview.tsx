import { createFileRoute } from '@tanstack/react-router';
import { OverviewPage } from '@/features/overview/overview-page';
import { requireAuth } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/overview')({
  beforeLoad: () => requireAuth(),
  component: OverviewPage,
});
