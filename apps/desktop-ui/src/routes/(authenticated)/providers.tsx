import { createFileRoute } from '@tanstack/react-router';
import { ProvidersPage } from '@/features/providers/providers-page';
import { requireAuth } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/providers')({
  beforeLoad: () => requireAuth(),
  component: ProvidersPage,
});
