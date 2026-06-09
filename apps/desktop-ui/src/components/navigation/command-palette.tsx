import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  CommandSeparator,
} from '@quotio/ui/components/command';
import { RiComputerLine, RiMoonLine, RiSunLine } from '@remixicon/react';
import { useNavigate } from '@tanstack/react-router';
import { useCallback, useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useTheme } from '@/components/theme-provider';
import { useAdminNavItems } from '@/lib/admin/navigation';

export function CommandPalette() {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const navigate = useNavigate();
  const { setTheme } = useTheme();
  const navItems = useAdminNavItems();

  useEffect(() => {
    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === 'k' && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        setOpen((current) => !current);
      }
    }
    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, []);

  const runCommand = useCallback((command: () => void) => {
    setOpen(false);
    command();
  }, []);

  return (
    <CommandDialog open={open} onOpenChange={setOpen}>
      <CommandInput placeholder={t('common.loading')} />
      <CommandList>
        <CommandEmpty>No results found.</CommandEmpty>
        <CommandGroup heading={t('nav.console')}>
          {navItems.map((item) => (
            <CommandItem
              key={item.url}
              value={`${item.title} ${item.description}`}
              onSelect={() => runCommand(() => navigate({ to: item.url }))}
            >
              <span className="[&>svg]:size-4">{item.icon}</span>
              <span>{item.title}</span>
            </CommandItem>
          ))}
        </CommandGroup>
        <CommandSeparator />
        <CommandGroup heading="Theme">
          <CommandItem
            value="light theme"
            onSelect={() => runCommand(() => setTheme('light'))}
          >
            <RiSunLine size={16} />
            <span>Light</span>
          </CommandItem>
          <CommandItem
            value="dark theme"
            onSelect={() => runCommand(() => setTheme('dark'))}
          >
            <RiMoonLine size={16} />
            <span>Dark</span>
          </CommandItem>
          <CommandItem
            value="system theme"
            onSelect={() => runCommand(() => setTheme('system'))}
          >
            <RiComputerLine size={16} />
            <span>System</span>
          </CommandItem>
        </CommandGroup>
      </CommandList>
    </CommandDialog>
  );
}
