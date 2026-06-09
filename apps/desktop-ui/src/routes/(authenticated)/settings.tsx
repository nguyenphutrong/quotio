import { createFileRoute } from '@tanstack/react-router';
import { useTranslation } from 'react-i18next';
import { PlaceholderPage } from '@/components/shared/-placeholder-page';
import { requireScreenFeature } from '@/lib/admin/auth-guard';

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
  beforeLoad: () => requireScreenFeature('settings'),
  component: SettingsPage,
});
