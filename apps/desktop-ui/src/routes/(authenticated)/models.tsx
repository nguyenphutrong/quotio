import { createFileRoute } from '@tanstack/react-router';
import { ModelsPage } from '@/features/models/models-page';
import { requireScreenFeature } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/models')({
  beforeLoad: () => requireScreenFeature('models'),
  component: ModelsPage,
});
