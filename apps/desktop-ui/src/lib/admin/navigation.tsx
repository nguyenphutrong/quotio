import {
  RiDashboardLine,
  RiDatabase2Line,
  RiExchangeFundsLine,
  RiFileList3Line,
  RiInformationLine,
  RiKey2Line,
  RiLineChartLine,
  RiListCheck,
  RiPuzzle2Line,
  RiSettings3Line,
  RiSwap2Line,
} from '@remixicon/react';
import type { ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import type { ScreenFeatureKey } from '@/lib/admin/bootstrap';
import { useAdminRuntime } from '@/lib/admin/runtime';

export type AdminNavItem = {
  title: string;
  url: string;
  icon: ReactNode;
  description: string;
  feature: ScreenFeatureKey;
};

export function useAdminNavItems(): AdminNavItem[] {
  const { t } = useTranslation();
  const { bootstrap } = useAdminRuntime();

  const items: AdminNavItem[] = [
    {
      title: t('nav.overview'),
      url: '/overview',
      icon: <RiDashboardLine />,
      description: t('nav.overviewDesc'),
      feature: 'overview',
    },
    {
      title: t('nav.providers'),
      url: '/providers',
      icon: <RiDatabase2Line />,
      description: t('nav.providersDesc'),
      feature: 'providers',
    },
    {
      title: t('nav.virtualModels'),
      url: '/virtual-models',
      icon: <RiSwap2Line />,
      description: t('nav.virtualModelsDesc'),
      feature: 'virtualModels',
    },
    {
      title: t('nav.models'),
      url: '/models',
      icon: <RiListCheck />,
      description: t('nav.modelsDesc'),
      feature: 'models',
    },
    {
      title: t('nav.agents'),
      url: '/agents',
      icon: <RiPuzzle2Line />,
      description: t('nav.agentsDesc'),
      feature: 'agents',
    },
    {
      title: t('nav.quota'),
      url: '/quota',
      icon: <RiExchangeFundsLine />,
      description: t('nav.quotaDesc'),
      feature: 'quota',
    },
    {
      title: t('nav.usage'),
      url: '/usage',
      icon: <RiLineChartLine />,
      description: t('nav.usageDesc'),
      feature: 'usage',
    },
    {
      title: t('nav.apiKeys'),
      url: '/api-keys',
      icon: <RiKey2Line />,
      description: t('nav.apiKeysDesc'),
      feature: 'apiKeys',
    },
    {
      title: t('nav.logs'),
      url: '/logs',
      icon: <RiFileList3Line />,
      description: t('nav.logsDesc'),
      feature: 'logs',
    },
    {
      title: t('nav.settings'),
      url: '/settings',
      icon: <RiSettings3Line />,
      description: t('nav.settingsDesc'),
      feature: 'settings',
    },
    {
      title: t('nav.about'),
      url: '/about',
      icon: <RiInformationLine />,
      description: t('nav.aboutDesc'),
      feature: 'about',
    },
  ];

  return items.filter((item) => bootstrap.features[item.feature]);
}

export function usePageMeta(pathname: string) {
  const { t } = useTranslation();
  const navItems = useAdminNavItems();
  const match = navItems.find((item) => item.url === pathname);

  if (match) {
    return {
      title: match.title,
      description: match.description,
    };
  }

  return {
    title: t('nav.defaultTitle'),
    description: t('nav.defaultDesc'),
  };
}
