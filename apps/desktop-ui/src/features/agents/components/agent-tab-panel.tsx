import { Badge } from '@quotio/ui/components/badge';
import { Button } from '@quotio/ui/components/button';
import { RiExternalLinkLine } from '@remixicon/react';
import { useEffect, useMemo, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { Panel } from '@/components/admin/panel';
import { useToast } from '@/components/admin/toast-provider';
import { useAgentActions } from '../api';
import type { AgentGuideResponse, AgentItem } from '../types';
import { safeArray, safeStr } from '../utils';
import { AgentActionButton } from './agent-action-button';
import { AgentGuideSheet } from './agent-guide-sheet';
import { AgentResultPanel } from './agent-result-panel';

const GUIDE_ONLY_AGENT_IDS = new Set(['cursor', 'openclaw', 'hermes']);

type AgentAction = 'guide' | 'diff' | 'install' | 'rollback';

export function AgentTabPanel({ agent }: { agent: AgentItem }) {
  const { t } = useTranslation();
  const toast = useToast();
  const actions = useAgentActions();
  const [isGuideOpen, setIsGuideOpen] = useState(false);
  const [guidePayload, setGuidePayload] =
    useState<AgentGuideResponse['guide']>();

  const state = actions.getActionState(agent.id);
  const capabilities = useMemo(
    () => safeArray<string>(agent.capabilities),
    [agent.capabilities],
  );
  const binaries = useMemo(
    () => safeArray<string>(agent.binaries),
    [agent.binaries],
  );
  const targetPaths = useMemo(
    () => safeArray<string>(agent.target_paths),
    [agent.target_paths],
  );
  const caveats = useMemo(
    () => safeArray<string>(agent.caveats),
    [agent.caveats],
  );
  const isGuideOnly = GUIDE_ONLY_AGENT_IDS.has(agent.id);
  const installedBadge =
    typeof state.installed === 'boolean'
      ? state.installed
        ? t('agents.badges.installed')
        : t('agents.badges.notInstalled')
      : null;
  const rollbackBadge =
    typeof state.rollbackAvailable === 'boolean'
      ? state.rollbackAvailable
        ? t('agents.badges.rollbackAvailable')
        : t('agents.badges.noBackup')
      : null;
  const actionStateLabel =
    state.status === 'running'
      ? t('agents.actionState.running')
      : state.status === 'success'
        ? t('agents.actionState.success')
        : state.status === 'error'
          ? t('agents.actionState.error')
          : '';

  useEffect(() => {
    return () => {
      actions.resetAgent(agent.id);
    };
  }, [actions, agent.id]);

  const run = async (action: AgentAction) => {
    try {
      const payload = await actions.runAction(agent.id, action);
      if (action === 'guide' && 'guide' in payload) {
        setGuidePayload(payload.guide);
        setIsGuideOpen(true);
      }
    } catch (error) {
      const message =
        error instanceof Error ? error.message : t('agents.unknownError');
      toast.error(`${t('agents.errors.actionFailed')}: ${message}`);
    }
  };

  return (
    <Panel className="space-y-4 overflow-x-hidden">
      <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
        <div className="space-y-2">
          <h2 className="text-lg font-semibold">
            {safeStr(agent.label, agent.id)}
          </h2>
          <div className="flex flex-wrap gap-2">
            {isGuideOnly ? (
              <Badge variant="secondary">{t('agents.badges.guideOnly')}</Badge>
            ) : null}
            <Badge variant="outline">{safeStr(agent.config_mode, '-')}</Badge>
            {installedBadge ? (
              <Badge variant={state.installed ? 'default' : 'secondary'}>
                {installedBadge}
              </Badge>
            ) : null}
            {rollbackBadge ? (
              <Badge variant="outline">{rollbackBadge}</Badge>
            ) : null}
          </div>
          {safeStr(agent.docs_url) ? (
            <a
              href={safeStr(agent.docs_url)}
              target="_blank"
              rel="noreferrer"
              className="inline-flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
            >
              {t('agents.sections.docs')}
              <RiExternalLinkLine className="size-3" />
            </a>
          ) : null}
        </div>

        <div className="flex flex-wrap gap-2">
          {capabilities.includes('guide') ? (
            <AgentActionButton
              label={t('agents.actions.viewGuide')}
              state={state.action === 'guide' ? state : { status: 'idle' }}
              onClick={() => void run('guide')}
            />
          ) : null}
          {!isGuideOnly && capabilities.includes('diff') ? (
            <AgentActionButton
              label={t('agents.actions.runDiff')}
              state={state.action === 'diff' ? state : { status: 'idle' }}
              onClick={() => void run('diff')}
            />
          ) : null}
          {!isGuideOnly && capabilities.includes('install') ? (
            <AgentActionButton
              label={t('agents.actions.install')}
              state={state.action === 'install' ? state : { status: 'idle' }}
              onClick={() => void run('install')}
            />
          ) : null}
          {!isGuideOnly && capabilities.includes('rollback') ? (
            <AgentActionButton
              label={t('agents.actions.rollback')}
              state={state.action === 'rollback' ? state : { status: 'idle' }}
              onClick={() => void run('rollback')}
            />
          ) : null}
        </div>
      </div>

      <div className="space-y-2 text-sm">
        <p>
          <span className="font-medium">{t('agents.sections.binaries')}:</span>{' '}
          {binaries.join(', ') || '-'}
        </p>
        <p>
          <span className="font-medium">{t('agents.sections.targets')}:</span>{' '}
          {targetPaths.join(', ') || '-'}
        </p>
        {caveats.length > 0 ? (
          <p>
            <span className="font-medium">{t('agents.sections.caveats')}:</span>{' '}
            {caveats.join(' | ')}
          </p>
        ) : null}
      </div>

      {state.status === 'error' ? (
        <div className="flex items-center justify-between gap-2 rounded-md border border-danger/30 bg-danger/10 p-2 text-sm text-danger">
          <span>{state.error ?? t('agents.errors.actionFailed')}</span>
          <Button
            size="sm"
            variant="ghost"
            onClick={() => state.action && void run(state.action)}
          >
            {t('agents.actions.retry')}
          </Button>
        </div>
      ) : null}

      <AgentResultPanel state={state} />
      <div className="sr-only" aria-live="polite">
        {actionStateLabel}
      </div>

      <AgentGuideSheet
        open={isGuideOpen}
        onOpenChange={setIsGuideOpen}
        label={safeStr(agent.label, agent.id)}
        guide={guidePayload}
      />
    </Panel>
  );
}
