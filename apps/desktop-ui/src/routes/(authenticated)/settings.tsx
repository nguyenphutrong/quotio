import { createFileRoute } from '@tanstack/react-router';
import { SettingsPage } from '@/features/settings/settings-page';
import { requireScreenFeature } from '@/lib/admin/auth-guard';

export const Route = createFileRoute('/(authenticated)/settings')({
  beforeLoad: () => requireScreenFeature('settings'),
  component: SettingsPage,
});
