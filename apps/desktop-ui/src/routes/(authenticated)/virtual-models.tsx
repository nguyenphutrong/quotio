import { createFileRoute } from '@tanstack/react-router';
import { VirtualModelsPage } from '@/features/virtual-models/virtual-models-page';
import { requireAuth } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/virtual-models')({
  beforeLoad: () => requireAuth(),
  component: VirtualModelsPage,
});
