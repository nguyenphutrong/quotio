import { createFileRoute, redirect } from '@tanstack/react-router';
import { requireAuth } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/')({
  beforeLoad: () => {
    requireAuth();
    throw redirect({ to: '/overview' });
  },
});
