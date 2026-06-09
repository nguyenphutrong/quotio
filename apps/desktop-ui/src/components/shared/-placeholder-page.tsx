import { useTranslation } from 'react-i18next';
import { AdminPageHeader } from '@/components/admin/admin-page-header';
import { Panel } from '@/components/admin/panel';

export function PlaceholderPage({
  title,
  description,
}: {
  title: string;
  description: string;
}) {
  const { t } = useTranslation();

  return (
    <div className="space-y-6">
      <AdminPageHeader title={title} description={description} />
      <Panel>
        <p className="text-sm leading-6 text-muted-foreground">
          {t('placeholder.comingSoon')}
        </p>
      </Panel>
    </div>
  );
}
