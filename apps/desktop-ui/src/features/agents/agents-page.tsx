import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from '@quotio/ui/components/tabs';
import { useEffect, useMemo, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { AdminPageHeader } from '@/components/admin/admin-page-header';
import { EmptyState } from '@/components/admin/empty-state';
import { ErrorState } from '@/components/admin/error-state';
import {
  HeaderActionsProvider,
  HeaderActionsSlot,
} from '@/components/admin/header-actions-portal';
import { LoadingState } from '@/components/admin/loading-state';
import { AmpCodePage } from '@/features/ampcode/ampcode-page';
import { useAgentsQuery } from './api';
import { AgentTabPanel } from './components/agent-tab-panel';
import { safeArray } from './utils';

const AMP_CODE_TAB = 'ampcode';

export function AgentsPage() {
  const { t } = useTranslation();
  const query = useAgentsQuery();
  const [selectedTab, setSelectedTab] = useState('');

  const agents = useMemo(
    () =>
      safeArray<AgentItem>(query.data?.agents).filter(
        (item) => item.id !== 'amp',
      ),
    [query.data?.agents],
  );

  useEffect(() => {
    const allTabs = [AMP_CODE_TAB, ...agents.map((item) => item.id)];
    if (allTabs.length === 0) {
      setSelectedTab('');
      return;
    }

    if (!selectedTab || !allTabs.includes(selectedTab)) {
      setSelectedTab(AMP_CODE_TAB);
    }
  }, [agents, selectedTab]);

  if (query.isPending) {
    return <LoadingState label={t('agents.loading')} />;
  }

  if (query.isError || !query.data) {
    return (
      <ErrorState
        title={t('agents.failedToLoad')}
        description={
          query.error instanceof Error
            ? query.error.message
            : t('agents.unknownError')
        }
      />
    );
  }

  if (agents.length === 0) {
    return (
      <HeaderActionsProvider>
        <div className="space-y-6">
          <AdminPageHeader
            title={t('agents.title')}
            description={t('agents.description')}
            actions={<HeaderActionsSlot className="flex items-center gap-2" />}
          />
          <EmptyState
            title={t('agents.empty.title')}
            description={t('agents.empty.description')}
          />
        </div>
      </HeaderActionsProvider>
    );
  }

  return (
    <HeaderActionsProvider>
      <div className="space-y-6">
        <AdminPageHeader
          title={t('agents.title')}
          description={t('agents.description')}
          actions={<HeaderActionsSlot className="flex items-center gap-2" />}
        />

        <Tabs value={selectedTab} onValueChange={setSelectedTab}>
          <TabsList className="h-auto max-w-full overflow-x-auto rounded-[1rem] bg-secondary/50 p-1.5">
            <TabsTrigger value={AMP_CODE_TAB}>
              {t('agents.ampcodeTab')}
            </TabsTrigger>
            {agents.map((item) => (
              <TabsTrigger key={item.id} value={item.id}>
                {item.label}
              </TabsTrigger>
            ))}
          </TabsList>

          <TabsContent value={AMP_CODE_TAB} className="mt-4">
            <AmpCodePage embedded />
          </TabsContent>

          {agents.map((item) => (
            <TabsContent key={item.id} value={item.id} className="mt-4">
              <AgentTabPanel agent={item} />
            </TabsContent>
          ))}
        </Tabs>
      </div>
    </HeaderActionsProvider>
  );
}

import type { AgentItem } from './types';
