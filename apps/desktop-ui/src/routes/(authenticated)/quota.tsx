import { createFileRoute } from '@tanstack/react-router';
import { QuotaPage } from '@/features/quota/quota-page';
import { requireScreenFeature } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/quota')({
  beforeLoad: () => requireScreenFeature('quota'),
  component: QuotaPage,
});
