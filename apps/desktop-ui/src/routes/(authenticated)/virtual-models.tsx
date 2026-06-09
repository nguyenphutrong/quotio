import { createFileRoute } from '@tanstack/react-router';
import { VirtualModelsPage } from '@/features/virtual-models/virtual-models-page';
import { requireScreenFeature } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/virtual-models')({
  beforeLoad: () => requireScreenFeature('virtualModels'),
  component: VirtualModelsPage,
});
