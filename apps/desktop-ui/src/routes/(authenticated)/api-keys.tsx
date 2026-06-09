import { createFileRoute } from '@tanstack/react-router';
import { APIKeysPage } from '@/features/api-keys/api-keys-page';
import { requireScreenFeature } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/api-keys')({
  beforeLoad: () => requireScreenFeature('apiKeys'),
  component: APIKeysPage,
});
