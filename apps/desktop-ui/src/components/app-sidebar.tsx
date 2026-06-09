'use client';

import { Logo } from '@quotio/ui/components/logo';
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from '@quotio/ui/components/sidebar';
import { RiBookOpenLine, RiGithubLine, RiQuestionLine } from '@remixicon/react';
import type * as React from 'react';
import { useTranslation } from 'react-i18next';
import { NavMain } from '@/components/nav-main';
import { NavUser } from '@/components/nav-user';
import { useAdminNavItems } from '@/lib/admin/navigation';
import { useAdminRuntime } from '@/lib/admin/runtime';
import { NavSecondary } from './nav-secondary';

export function AppSidebar({ ...props }: React.ComponentProps<typeof Sidebar>) {
  const { t } = useTranslation();
  const { clearToken } = useAdminRuntime();
  const adminNavItems = useAdminNavItems();

  const supportItems = [
    {
      title: t('nav.docs'),
      url: 'https://github.com/nguyenphutrong/quotio#readme',
      icon: <RiBookOpenLine />,
    },
    {
      title: t('nav.github'),
      url: 'https://github.com/nguyenphutrong/quotio',
      icon: <RiGithubLine />,
    },
    {
      title: t('nav.support'),
      url: 'https://github.com/nguyenphutrong/quotio/issues',
      icon: <RiQuestionLine />,
    },
  ];

  function handleSignOut() {
    clearToken();
  }

  return (
    <Sidebar variant="inset" {...props}>
      <SidebarHeader>
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton size="lg" className="pointer-events-none">
              <Logo size={32} />
              <div className="grid flex-1 text-left text-sm leading-tight">
                <span className="truncate font-heading font-medium">
                  {t('common.adminPanel')}
                </span>
                <span className="truncate text-[11px] uppercase tracking-wider text-muted-foreground">
                  {t('common.tagline')}
                </span>
              </div>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarHeader>
      <SidebarContent>
        <NavMain items={adminNavItems} label={t('nav.console')} />
        <NavSecondary
          items={supportItems}
          label={t('nav.resources')}
          className="mt-auto"
        />
      </SidebarContent>
      <SidebarFooter>
        <NavUser
          user={{
            name: t('shell.sessionLabel'),
            email: t('shell.sessionDetail'),
            avatar: '',
          }}
          onClearToken={handleSignOut}
        />
      </SidebarFooter>
    </Sidebar>
  );
}
