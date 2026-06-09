import { createFileRoute } from '@tanstack/react-router';
import { AgentsPage } from '@/features/agents/agents-page';
import { requireScreenFeature } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/agents')({
  beforeLoad: () => requireScreenFeature('agents'),
  component: AgentsPage,
});
