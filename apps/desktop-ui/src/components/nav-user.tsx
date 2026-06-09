import {
  Avatar,
  AvatarFallback,
  AvatarImage,
} from '@quotio/ui/components/avatar';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@quotio/ui/components/dropdown-menu';
import {
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  useSidebar,
} from '@quotio/ui/components/sidebar';
import { cn } from '@quotio/ui/lib/utils';
import {
  RiArrowUpDownLine,
  RiComputerLine,
  RiLogoutBoxLine,
  RiMoonLine,
  RiRefreshLine,
  RiSunLine,
} from '@remixicon/react';
import { useTranslation } from 'react-i18next';
import { useTheme } from '@/components/theme-provider';

const themeOptions = [
  { value: 'light', icon: RiSunLine, label: 'Light' },
  { value: 'dark', icon: RiMoonLine, label: 'Dark' },
  { value: 'system', icon: RiComputerLine, label: 'System' },
] as const;

export function NavUser({
  user,
  onClearToken,
}: {
  user: {
    name: string;
    email: string;
    avatar: string;
  };
  onClearToken: () => void;
}) {
  const { t } = useTranslation();
  const { isMobile } = useSidebar();
  const { theme, setTheme } = useTheme();
  return (
    <SidebarMenu>
      <SidebarMenuItem>
        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <SidebarMenuButton size="lg" className="aria-expanded:bg-muted" />
            }
          >
            <Avatar>
              <AvatarImage src={user.avatar} alt={user.name} />
              <AvatarFallback>CN</AvatarFallback>
            </Avatar>
            <div className="grid flex-1 text-left text-sm leading-tight">
              <span className="truncate font-medium">{user.name}</span>
              <span className="truncate text-xs">{user.email}</span>
            </div>
            <RiArrowUpDownLine className="ml-auto size-4" />
          </DropdownMenuTrigger>
          <DropdownMenuContent
            className="min-w-56 rounded-lg"
            side={isMobile ? 'bottom' : 'right'}
            align="end"
            sideOffset={4}
          >
            <DropdownMenuGroup>
              <DropdownMenuLabel className="p-0 font-normal">
                <div className="flex items-center gap-2 px-1 py-1.5 text-left text-sm">
                  <Avatar>
                    <AvatarImage src={user.avatar} alt={user.name} />
                    <AvatarFallback>CN</AvatarFallback>
                  </Avatar>
                  <div className="grid flex-1 text-left text-sm leading-tight">
                    <span className="truncate font-medium">{user.name}</span>
                    <span className="truncate text-xs">{user.email}</span>
                  </div>
                </div>
              </DropdownMenuLabel>
            </DropdownMenuGroup>
            <DropdownMenuSeparator />
            <DropdownMenuLabel className="flex items-center justify-between py-1.5">
              <span className="text-[11px] font-normal uppercase tracking-wider text-muted-foreground">
                Theme
              </span>
              <div className="flex items-center gap-0.5 rounded-md border border-border/50 p-0.5">
                {themeOptions.map((opt) => (
                  <button
                    key={opt.value}
                    type="button"
                    onClick={() => setTheme(opt.value)}
                    className={cn(
                      'flex size-6 items-center justify-center rounded-sm transition-colors',
                      theme === opt.value
                        ? 'bg-surface-1 text-foreground'
                        : 'text-muted-foreground hover:text-foreground',
                    )}
                    title={opt.label}
                    aria-label={opt.label}
                  >
                    <opt.icon size={13} />
                  </button>
                ))}
              </div>
            </DropdownMenuLabel>
            <DropdownMenuSeparator />
            <DropdownMenuGroup>
              <DropdownMenuItem onClick={() => window.location.reload()}>
                <RiRefreshLine />
                {t('shell.reloadAdmin')}
              </DropdownMenuItem>
            </DropdownMenuGroup>
            <DropdownMenuSeparator />
            <DropdownMenuItem onClick={onClearToken}>
              <RiLogoutBoxLine />
              {t('auth.signOut')}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </SidebarMenuItem>
    </SidebarMenu>
  );
}
