import {
  RiDashboardLine,
  RiDatabase2Line,
  RiExchangeFundsLine,
  RiFileList3Line,
  RiInformationLine,
  RiKey2Line,
  RiListCheck,
  RiPuzzle2Line,
  RiSettings3Line,
  RiSwap2Line,
} from '@remixicon/react';
import type { ReactNode } from 'react';
import { useTranslation } from 'react-i18next';

export type AdminNavItem = {
  title: string;
  url: string;
  icon: ReactNode;
  description: string;
};

export function useAdminNavItems(): AdminNavItem[] {
  const { t } = useTranslation();

  return [
    {
      title: t('nav.overview'),
      url: '/overview',
      icon: <RiDashboardLine />,
      description: t('nav.overviewDesc'),
    },
    {
      title: t('nav.providers'),
      url: '/providers',
      icon: <RiDatabase2Line />,
      description: t('nav.providersDesc'),
    },
    {
      title: t('nav.virtualModels'),
      url: '/virtual-models',
      icon: <RiSwap2Line />,
      description: t('nav.virtualModelsDesc'),
    },
    {
      title: t('nav.models'),
      url: '/models',
      icon: <RiListCheck />,
      description: t('nav.modelsDesc'),
    },
    {
      title: t('nav.agents'),
      url: '/agents',
      icon: <RiPuzzle2Line />,
      description: t('nav.agentsDesc'),
    },
    {
      title: t('nav.quota'),
      url: '/quota',
      icon: <RiExchangeFundsLine />,
      description: t('nav.quotaDesc'),
    },
    {
      title: t('nav.apiKeys'),
      url: '/api-keys',
      icon: <RiKey2Line />,
      description: t('nav.apiKeysDesc'),
    },
    {
      title: t('nav.logs'),
      url: '/logs',
      icon: <RiFileList3Line />,
      description: t('nav.logsDesc'),
    },
    {
      title: t('nav.settings'),
      url: '/settings',
      icon: <RiSettings3Line />,
      description: t('nav.settingsDesc'),
    },
    {
      title: t('nav.about'),
      url: '/about',
      icon: <RiInformationLine />,
      description: t('nav.aboutDesc'),
    },
  ];
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
