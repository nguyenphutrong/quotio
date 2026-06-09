import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from '@quotio/ui/components/collapsible';
import { RiArrowDownSLine } from '@remixicon/react';
import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import type { AgentActionState } from '../api';
import type { AgentDiffResponse, AgentInstallResponse } from '../types';
import { safeArray } from '../utils';
import { AgentDiffView } from './agent-diff-view';

function hasStatusWithPlan(
  payload: unknown,
): payload is AgentDiffResponse | AgentInstallResponse {
  return (
    typeof payload === 'object' &&
    payload !== null &&
    'status' in payload &&
    'plan' in payload
  );
}

export function AgentResultPanel({ state }: { state: AgentActionState }) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);

  if (!state.payload) {
    return null;
  }

  const payload = state.payload;
  const files =
    hasStatusWithPlan(payload) && 'files' in payload.plan
      ? safeArray<{
          target_path: string;
          existed: boolean;
          has_changes: boolean;
          before?: string;
          after?: string;
        }>(payload.plan.files)
      : [];

  return (
    <div className="space-y-3 rounded-md border border-border/70 p-3">
      <p className="text-sm font-medium">{t('agents.sections.lastResult')}</p>

      {files.length > 0 ? <AgentDiffView files={files} /> : null}

      <Collapsible open={open} onOpenChange={setOpen}>
        <CollapsibleTrigger className="inline-flex items-center gap-1 text-sm text-muted-foreground">
          <RiArrowDownSLine className="size-4" />
          {open ? t('agents.payload.hide') : t('agents.payload.show')}
        </CollapsibleTrigger>
        <CollapsibleContent>
          <pre className="mt-2 max-h-72 overflow-auto rounded-md border border-border/70 bg-muted/30 p-3 text-xs">
            {JSON.stringify(payload, null, 2)}
          </pre>
        </CollapsibleContent>
      </Collapsible>
    </div>
  );
}
