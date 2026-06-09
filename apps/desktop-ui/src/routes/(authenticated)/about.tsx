import { createFileRoute } from '@tanstack/react-router';
import { useTranslation } from 'react-i18next';
import { PlaceholderPage } from '@/components/shared/-placeholder-page';
import { requireAuth } from '@/lib/admin/auth-guard';

function AboutPage() {
  const { t } = useTranslation();
  return (
    <PlaceholderPage
      title={t('nav.about')}
      description={t('placeholder.aboutDesc')}
    />
  );
}

export const Route = createFileRoute('/(authenticated)/about')({
  beforeLoad: () => requireAuth(),
  component: AboutPage,
});
