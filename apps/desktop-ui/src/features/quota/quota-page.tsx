import { Button } from '@quotio/ui/components/button';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@quotio/ui/components/dropdown-menu';
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from '@quotio/ui/components/tabs';
import { RiApps2Line, RiFilter3Line, RiRefreshLine } from '@remixicon/react';
import { useEffect, useMemo, useState } from 'react';
import { AdminPageHeader } from '@/components/admin/admin-page-header';
import { EmptyState } from '@/components/admin/empty-state';
import { ErrorState } from '@/components/admin/error-state';
import { LoadingState } from '@/components/admin/loading-state';
import { ProviderIcon } from '@/components/admin/provider-icon';
import { getProviderDisplayName } from '@/features/providers/types';
import {
  quotaAutoRefreshIntervalMs,
  useQuotaMutations,
  useQuotaQuery,
} from './api';
import { AccountCard } from './components/account-card';
import type {
  QuotaAccountView,
  QuotaDisplayMode,
  QuotaDisplayStyle,
  QuotaProviderView,
} from './types';
import { formatCountdown } from './utils';

const allProvidersId = '__all__';
const displayModeKey = 'quota-display-mode';
const displayStyleKey = 'quota-display-style';

function loadPreference<T extends string>(key: string, fallback: T): T {
  if (typeof window === 'undefined') return fallback;
  const value = window.localStorage.getItem(key);
  return (value as T) || fallback;
}

export function QuotaPage() {
  const query = useQuotaQuery();
  const mutations = useQuotaMutations();
  const [selectedProvider, setSelectedProvider] = useState(allProvidersId);
  const [displayMode, setDisplayMode] = useState<QuotaDisplayMode>(() =>
    loadPreference(displayModeKey, 'remaining'),
  );
  const [displayStyle, setDisplayStyle] = useState<QuotaDisplayStyle>(() =>
    loadPreference(displayStyleKey, 'overview'),
  );
  const [refreshingKey, setRefreshingKey] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());

  const providers = query.data?.providers ?? [];
  const supportedProviders = useMemo(
    () => providers.filter((provider) => provider.quota_supported),
    [providers],
  );

  useEffect(() => {
    const interval = window.setInterval(() => {
      setNow(Date.now());
    }, 1000);
    return () => {
      window.clearInterval(interval);
    };
  }, []);

  useEffect(() => {
    if (
      selectedProvider !== allProvidersId &&
      !supportedProviders.some(
        (provider) => provider.provider === selectedProvider,
      )
    ) {
      setSelectedProvider(allProvidersId);
    }
  }, [selectedProvider, supportedProviders]);

  const providerTabs = useMemo(
    () => [
      { provider: allProvidersId, display_name: 'All' },
      ...supportedProviders.map((provider) => ({
        ...provider,
        display_name: getProviderDisplayName(
          provider.provider,
          provider.display_name,
        ),
      })),
    ],
    [supportedProviders],
  );

  const allAccounts = useMemo(
    () =>
      supportedProviders.flatMap((provider) =>
        provider.accounts.map((account) => ({
          provider,
          account,
        })),
      ),
    [supportedProviders],
  );

  const nextAutoRefreshAt = query.dataUpdatedAt + quotaAutoRefreshIntervalMs;
  const autoRefreshLabel =
    refreshingKey === 'all'
      ? 'Refreshing...'
      : query.dataUpdatedAt > 0
        ? `Auto refresh in ${formatCountdown(nextAutoRefreshAt - now)}`
        : 'Auto refresh every 5m';

  const setMode = (next: QuotaDisplayMode) => {
    setDisplayMode(next);
    if (typeof window !== 'undefined') {
      window.localStorage.setItem(displayModeKey, next);
    }
  };

  const setStyle = (next: QuotaDisplayStyle) => {
    setDisplayStyle(next);
    if (typeof window !== 'undefined') {
      window.localStorage.setItem(displayStyleKey, next);
    }
  };

  const refreshAll = async () => {
    setRefreshingKey('all');
    try {
      await mutations.refreshAllMutation.mutateAsync();
    } finally {
      setRefreshingKey(null);
    }
  };

  const refreshAccount = async (provider: string, credentialId: string) => {
    const key = `${provider}:${credentialId}`;
    setRefreshingKey(key);
    try {
      await mutations.refreshAccountMutation.mutateAsync({
        provider,
        credentialId,
      });
    } finally {
      setRefreshingKey(null);
    }
  };

  const switchAccount = async (provider: string, account: QuotaAccountView) => {
    setRefreshingKey(`switch:${provider}:${account.credential_id}`);
    try {
      await mutations.switchAccountMutation.mutateAsync({
        provider,
        id: account.credential_id,
      });
    } finally {
      setRefreshingKey(null);
    }
  };

  if (query.isLoading) {
    return <LoadingState label="Loading quota data..." />;
  }

  if (query.isError) {
    return (
      <ErrorState
        title="Failed to load quota"
        description={
          query.error instanceof Error ? query.error.message : 'Unknown error'
        }
        actionLabel="Retry"
        onAction={() => {
          void query.refetch();
        }}
      />
    );
  }

  if (!query.data || supportedProviders.length === 0) {
    return (
      <EmptyState
        title="No quota providers"
        description="No configured providers currently support quota in Quotio."
      />
    );
  }

  return (
    <div className="flex flex-1 flex-col pb-8">
      <AdminPageHeader
        title="Quota"
        description="Monitor provider quotas by account with live refresh and switching controls."
        actions={
          <div className="flex flex-wrap items-center gap-2">
            <DropdownMenu>
              <DropdownMenuTrigger
                render={
                  <Button variant="outline" size="sm" className="h-8 gap-2">
                    <RiFilter3Line className="h-4 w-4" />
                    Display Options
                  </Button>
                }
              />
              <DropdownMenuContent align="end" className="w-48">
                <DropdownMenuGroup>
                  <DropdownMenuLabel>Style</DropdownMenuLabel>
                  <DropdownMenuRadioGroup
                    value={displayStyle}
                    onValueChange={(v) => setStyle(v as QuotaDisplayStyle)}
                  >
                    <DropdownMenuRadioItem value="overview">
                      Overview
                    </DropdownMenuRadioItem>
                    <DropdownMenuRadioItem value="focus">
                      Focus
                    </DropdownMenuRadioItem>
                  </DropdownMenuRadioGroup>
                </DropdownMenuGroup>
                <DropdownMenuSeparator />
                <DropdownMenuGroup>
                  <DropdownMenuLabel>Value Mode</DropdownMenuLabel>
                  <DropdownMenuRadioGroup
                    value={displayMode}
                    onValueChange={(v) => setMode(v as QuotaDisplayMode)}
                  >
                    <DropdownMenuRadioItem value="remaining">
                      Remaining
                    </DropdownMenuRadioItem>
                    <DropdownMenuRadioItem value="used">
                      Used
                    </DropdownMenuRadioItem>
                  </DropdownMenuRadioGroup>
                </DropdownMenuGroup>
              </DropdownMenuContent>
            </DropdownMenu>
            <Button
              variant="outline"
              size="sm"
              className="h-8 gap-2"
              onClick={refreshAll}
              disabled={refreshingKey === 'all'}
            >
              <RiRefreshLine
                className={`h-4 w-4 ${refreshingKey === 'all' ? 'animate-spin' : ''}`}
              />
              {autoRefreshLabel}
            </Button>
          </div>
        }
      />

      <div className="container w-full max-w-none">
        <Tabs value={selectedProvider} onValueChange={setSelectedProvider}>
          <TabsList className="mb-6 h-auto w-max min-w-0 justify-start gap-1 rounded-[1rem] bg-secondary/50 p-1.5">
            {providerTabs.map((provider) => (
              <TabsTrigger
                key={provider.provider}
                value={provider.provider}
                className="rounded-xl px-4 py-2 text-sm font-medium"
              >
                <span className="inline-flex items-center gap-2">
                  <span className="flex h-5 w-5 shrink-0 items-center justify-center rounded-md border border-border bg-muted">
                    {provider.provider === allProvidersId ? (
                      <RiApps2Line className="h-3.5 w-3.5 text-muted-foreground" />
                    ) : (
                      <ProviderIcon
                        provider={provider.provider}
                        className="h-3.5 w-3.5"
                      />
                    )}
                  </span>
                  <span>{provider.display_name}</span>
                </span>
              </TabsTrigger>
            ))}
          </TabsList>

          <TabsContent value={allProvidersId} className="mt-0 outline-none">
            <div className="grid gap-4 md:grid-cols-2">
              {allAccounts.map(({ provider, account }) => (
                <AccountCard
                  key={`${provider.provider}:${account.credential_id}`}
                  account={account}
                  displayMode={displayMode}
                  displayStyle={displayStyle}
                  now={now}
                  onRefresh={() =>
                    refreshAccount(provider.provider, account.credential_id)
                  }
                  onSwitchAccount={
                    provider.supports_account_switch &&
                    account.quota_supported &&
                    !account.is_active
                      ? () => switchAccount(provider.provider, account)
                      : undefined
                  }
                  isRefreshing={
                    refreshingKey ===
                    `${provider.provider}:${account.credential_id}`
                  }
                  isSwitching={
                    refreshingKey ===
                    `switch:${provider.provider}:${account.credential_id}`
                  }
                />
              ))}
            </div>
          </TabsContent>

          {supportedProviders.map((provider: QuotaProviderView) => (
            <TabsContent
              key={provider.provider}
              value={provider.provider}
              className="mt-0 outline-none"
            >
              <div className="grid gap-4 md:grid-cols-2">
                {provider.accounts.map((account) => (
                  <AccountCard
                    key={`${provider.provider}:${account.credential_id}`}
                    account={account}
                    displayMode={displayMode}
                    displayStyle={displayStyle}
                    now={now}
                    onRefresh={() =>
                      refreshAccount(provider.provider, account.credential_id)
                    }
                    onSwitchAccount={
                      provider.supports_account_switch &&
                      account.quota_supported &&
                      !account.is_active
                        ? () => switchAccount(provider.provider, account)
                        : undefined
                    }
                    isRefreshing={
                      refreshingKey ===
                      `${provider.provider}:${account.credential_id}`
                    }
                    isSwitching={
                      refreshingKey ===
                      `switch:${provider.provider}:${account.credential_id}`
                    }
                  />
                ))}
              </div>
            </TabsContent>
          ))}
        </Tabs>
      </div>
    </div>
  );
}
