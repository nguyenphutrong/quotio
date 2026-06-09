import { createFileRoute, redirect } from '@tanstack/react-router';
import { requireAuth } from '@/lib/admin/auth-guard';
import {
  getDesktopBootstrap,
  getFirstEnabledRoute,
} from '@/lib/admin/bootstrap';

export const Route = createFileRoute('/(authenticated)/')({
  beforeLoad: () => {
    requireAuth();
    throw redirect({
      to: getFirstEnabledRoute(getDesktopBootstrap().features),
    });
  },
});
