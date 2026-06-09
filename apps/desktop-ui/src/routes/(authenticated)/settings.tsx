import { createFileRoute } from '@tanstack/react-router';
import { useTranslation } from 'react-i18next';
import { PlaceholderPage } from '@/components/shared/-placeholder-page';
import { requireAuth } from '@/lib/admin/auth-guard';

function SettingsPage() {
  const { t } = useTranslation();
  return (
    <PlaceholderPage
      title={t('nav.settings')}
      description={t('placeholder.settingsDesc')}
    />
  );
}

export const Route = createFileRoute('/(authenticated)/settings')({
  beforeLoad: () => requireAuth(),
  component: SettingsPage,
});
