'use client';

import { Logo } from '@quotio/ui/components/logo';
import {
  Sidebar,
  SidebarContent,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from '@quotio/ui/components/sidebar';
import type * as React from 'react';
import { useTranslation } from 'react-i18next';
import { NavMain } from '@/components/nav-main';
import { useAdminNavItems } from '@/lib/admin/navigation';
import { useIsNativeDesktopRuntime } from '@/lib/admin/runtime';

export function AppSidebar({ ...props }: React.ComponentProps<typeof Sidebar>) {
  const { t } = useTranslation();
  const adminNavItems = useAdminNavItems();
  const isNativeDesktop = useIsNativeDesktopRuntime();

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
    </Sidebar>
  );
}
