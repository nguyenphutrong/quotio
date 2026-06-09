import { createFileRoute } from '@tanstack/react-router';
import { z } from 'zod';
import { LogsPage } from '@/features/request-logs/logs-page';
import { requireAuth } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/logs')({
  beforeLoad: () => requireAuth(),
  validateSearch: z.object({
    apiKeyId: z.string().optional(),
    cursor: z.string().optional(),
  }),
  component: LogsPage,
});
