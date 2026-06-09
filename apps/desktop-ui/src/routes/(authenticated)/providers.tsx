import { createFileRoute } from '@tanstack/react-router';
import { ProvidersPage } from '@/features/providers/providers-page';
import { requireScreenFeature } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/providers')({
  beforeLoad: () => requireScreenFeature('providers'),
  component: ProvidersPage,
});
