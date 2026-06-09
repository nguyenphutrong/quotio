import { createFileRoute } from '@tanstack/react-router';
import { QuotaPage } from '@/features/quota/quota-page';
import { requireAuth } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/quota')({
  beforeLoad: () => requireAuth(),
  component: QuotaPage,
});
