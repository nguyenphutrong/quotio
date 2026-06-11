import { Button } from '@quotio/ui/components/button';
import { RiBookOpenLine, RiGithubLine, RiQuestionLine } from '@remixicon/react';
import { createFileRoute } from '@tanstack/react-router';
import { useTranslation } from 'react-i18next';
import { AdminPageHeader } from '@/components/admin/admin-page-header';
import { Panel } from '@/components/admin/panel';
import { StatusBadge } from '@/components/admin/status-badge';
import { requireScreenFeature } from '@/lib/admin/auth-guard';
import type {
  AdminFeatureFlags,
  HostCapabilities,
} from '@/lib/admin/bootstrap';
import { useAdminRuntime } from '@/lib/admin/runtime';

const FEATURE_KEYS = [
  'overview',
  'providers',
  'quota',
  'usage',
  'virtualModels',
  'models',
  'agents',
  'apiKeys',
  'logs',
  'settings',
  'about',
] satisfies (keyof AdminFeatureFlags)[];

const CAPABILITY_KEYS = [
  'supportsLocalProxy',
  'supportsProxyControl',
  'supportsPortConfig',
  'supportsCliOAuth',
  'supportsAgentConfig',
  'supportsRemoteConnections',
  'supportsCredentialStorage',
  'supportsManagementBridge',
  'supportsNativeOnboarding',
  'supportsNativePreferences',
  'supportsAppearanceSync',
  'supportsRequestLogSettings',
  'supportsModelSettings',
  'supportsApiKeyManagement',
  'supportsVirtualModelManagement',
  'supportsUpdates',
] satisfies (keyof HostCapabilities)[];

function DiagnosticsRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex min-h-10 items-center justify-between gap-4 border-border border-b py-2 last:border-b-0">
      <dt className="text-muted-foreground text-sm">{label}</dt>
      <dd className="flex min-w-0 items-center gap-2 text-right">
        <span className="truncate text-foreground text-sm">{value}</span>
      </dd>
    </div>
  );
}

function FlagList({
  values,
  labelsPrefix,
}: {
  values: Record<string, boolean>;
  labelsPrefix: string;
}) {
  const { t } = useTranslation();

  return (
    <div className="grid gap-2 md:grid-cols-2">
      {Object.entries(values).map(([key, enabled]) => (
        <div
          className="flex min-h-9 items-center justify-between gap-3 rounded-lg border border-border bg-muted/30 px-3 py-2"
          key={key}
        >
          <span className="min-w-0 truncate text-sm">
            {t(`${labelsPrefix}.${key}`)}
          </span>
          <StatusBadge tone={enabled ? 'success' : 'neutral'}>
            {enabled ? t('about.status.enabled') : t('about.status.disabled')}
          </StatusBadge>
        </div>
      ))}
    </div>
  );
}

function AboutPage() {
  const { t } = useTranslation();
  const { bootstrap, openExternal } = useAdminRuntime();

  const featureValues = Object.fromEntries(
    FEATURE_KEYS.map((key) => [key, bootstrap.features[key]]),
  );
  const capabilityValues = Object.fromEntries(
    CAPABILITY_KEYS.map((key) => [key, bootstrap.capabilities[key]]),
  );
  const resources = [
    {
      title: t('nav.docs'),
      url: 'https://github.com/nguyenphutrong/quotio#readme',
      icon: <RiBookOpenLine className="h-4 w-4" />,
    },
    {
      title: t('nav.github'),
      url: 'https://github.com/nguyenphutrong/quotio',
      icon: <RiGithubLine className="h-4 w-4" />,
    },
    {
      title: t('nav.support'),
      url: 'https://github.com/nguyenphutrong/quotio/issues',
      icon: <RiQuestionLine className="h-4 w-4" />,
    },
  ];

  return (
    <div className="space-y-6">
      <AdminPageHeader
        title={t('nav.about')}
        description={t('about.description')}
      />

      <Panel>
        <div className="mb-3">
          <h2 className="font-medium text-foreground text-sm">
            {t('about.sections.resources')}
          </h2>
          <p className="mt-1 text-muted-foreground text-sm">
            {t('about.sections.resourcesDesc')}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          {resources.map((item) => (
            <Button
              key={item.title}
              type="button"
              variant="outline"
              size="sm"
              onClick={() => void openExternal(item.url)}
            >
              {item.icon}
              {item.title}
            </Button>
          ))}
        </div>
      </Panel>

      <Panel>
        <h2 className="font-medium text-foreground text-sm">
          {t('about.sections.host')}
        </h2>
        <dl className="mt-3">
          <DiagnosticsRow
            label={t('about.fields.platform')}
            value={t(`about.platform.${bootstrap.platform}`)}
          />
          <DiagnosticsRow
            label={t('about.fields.operatingMode')}
            value={t(`about.operatingMode.${bootstrap.operatingMode}`)}
          />
          <DiagnosticsRow
            label={t('about.fields.locale')}
            value={bootstrap.locale}
          />
          <DiagnosticsRow
            label={t('about.fields.appearance')}
            value={t(`about.appearance.${bootstrap.appearance}`)}
          />
        </dl>
      </Panel>

      <Panel>
        <details>
          <summary className="font-medium text-foreground text-sm">
            {t('about.sections.troubleshooting')}
          </summary>
          <div className="mt-3 space-y-5">
            <dl>
              <DiagnosticsRow
                label={t('about.fields.bridgeVersion')}
                value={String(bootstrap.bridgeVersion)}
              />
              <DiagnosticsRow
                label={t('about.fields.serverListen')}
                value={t('about.values.localGatewayReady')}
              />
            </dl>
            <div>
              <div className="mb-3">
                <h3 className="font-medium text-foreground text-sm">
                  {t('about.sections.routes')}
                </h3>
                <p className="mt-1 text-muted-foreground text-sm">
                  {t('about.sections.routesDesc')}
                </p>
              </div>
              <FlagList labelsPrefix="about.features" values={featureValues} />
            </div>
            <div>
              <div className="mb-3">
                <h3 className="font-medium text-foreground text-sm">
                  {t('about.sections.capabilities')}
                </h3>
                <p className="mt-1 text-muted-foreground text-sm">
                  {t('about.sections.capabilitiesDesc')}
                </p>
              </div>
              <FlagList
                labelsPrefix="about.capabilities"
                values={capabilityValues}
              />
            </div>
          </div>
        </details>
      </Panel>
    </div>
  );
}

export const Route = createFileRoute('/(authenticated)/about')({
  beforeLoad: () => requireScreenFeature('about'),
  component: AboutPage,
});
