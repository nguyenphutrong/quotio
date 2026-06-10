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
import type * as React from 'react';
import { useTranslation } from 'react-i18next';
import { NavMain } from '@/components/nav-main';
import { useAdminNavItems } from '@/lib/admin/navigation';
import {
  useAdminRuntime,
  useIsNativeDesktopRuntime,
} from '@/lib/admin/runtime';

export function AppSidebar({ ...props }: React.ComponentProps<typeof Sidebar>) {
  const { t } = useTranslation();
  const adminNavItems = useAdminNavItems();
  const isNativeDesktop = useIsNativeDesktopRuntime();
  const { bootstrap, isAuthenticated } = useAdminRuntime();

  return (
    <Sidebar
      collapsible={isNativeDesktop ? 'none' : 'offcanvas'}
      variant={isNativeDesktop ? 'sidebar' : 'inset'}
      {...props}
    >
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
      </SidebarContent>
      <SidebarFooter className="border-sidebar-border border-t">
        <div className="flex items-center justify-between gap-3 rounded-md px-2 py-1.5 text-xs">
          <div className="flex min-w-0 items-center gap-2">
            <span
              className={
                isAuthenticated
                  ? 'size-2 rounded-full bg-emerald-500'
                  : 'size-2 rounded-full bg-muted-foreground'
              }
            />
            <span className="truncate text-sidebar-foreground">
              {isAuthenticated
                ? t('shell.adminConnected')
                : t('shell.authRequired')}
            </span>
          </div>
          <span className="truncate text-sidebar-foreground/60">
            {t(`about.operatingMode.${bootstrap.operatingMode}`)}
          </span>
        </div>
      </SidebarFooter>
    </Sidebar>
  );
}
