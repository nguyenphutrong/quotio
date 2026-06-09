import { createFileRoute } from '@tanstack/react-router';
import { ModelsPage } from '@/features/models/models-page';
import { requireAuth } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/models')({
  beforeLoad: () => requireAuth(),
  component: ModelsPage,
});
