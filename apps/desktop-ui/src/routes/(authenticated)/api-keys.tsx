import { createFileRoute } from '@tanstack/react-router';
import { APIKeysPage } from '@/features/api-keys/api-keys-page';
import { requireAuth } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/api-keys')({
  beforeLoad: () => requireAuth(),
  component: APIKeysPage,
});
