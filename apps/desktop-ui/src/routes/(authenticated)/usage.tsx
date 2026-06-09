import { createFileRoute } from '@tanstack/react-router';
import { UsageStatsPage } from '@/features/usage-stats/usage-stats-page';
import { requireScreenFeature } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/usage')({
  beforeLoad: () => requireScreenFeature('usage'),
  component: UsageStatsPage,
});
