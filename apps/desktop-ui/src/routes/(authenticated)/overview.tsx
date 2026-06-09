import { createFileRoute } from '@tanstack/react-router';
import { OverviewPage } from '@/features/overview/overview-page';
import { requireScreenFeature } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/overview')({
  beforeLoad: () => requireScreenFeature('overview'),
  component: OverviewPage,
});
