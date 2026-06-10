import { Badge } from '@quotio/ui/components/badge';
import { Button } from '@quotio/ui/components/button';
import { RiExternalLinkLine } from '@remixicon/react';
import { useTranslation } from 'react-i18next';
import { CopyButton } from '@/components/admin/copy-button';
import { Panel } from '@/components/admin/panel';
import { useAdminRuntime } from '@/lib/admin/runtime';
import type { AgentGuideResponse } from '../types';
import { safeArray, safeStr } from '../utils';

type AgentGuideSheetProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  label: string;
  guide?: AgentGuideResponse['guide'];
};

export function AgentGuideSheet({
  open,
  onOpenChange,
  label,
  guide,
}: AgentGuideSheetProps) {
  const { t } = useTranslation();
  const { openExternal } = useAdminRuntime();

  const steps = safeArray<string>(guide?.steps);
  const verify = safeArray<string>(guide?.verify);
  const caveats = safeArray<string>(guide?.caveats);
  const docsUrl = safeStr(guide?.docs_url);
  const configSnippet = safeStr(guide?.config_snippet);
  const envSnippet = safeStr(guide?.env_snippet);

  if (!open) {
    return null;
  }

  return (
    <Panel className="space-y-5">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h2 className="text-sm font-semibold text-foreground">
            {label} · {t('agents.guide.title')}
          </h2>
          {docsUrl ? (
            <div className="mt-2 flex flex-wrap items-center gap-2">
              <Button
                type="button"
                variant="outline"
                size="xs"
                onClick={() => void openExternal(docsUrl)}
              >
                <RiExternalLinkLine />
                {t('agents.actions.openDocs')}
              </Button>
              <CopyButton
                value={docsUrl}
                variant="ghost"
                size="xs"
                successMessage={t('agents.actions.copied')}
              >
                {t('agents.actions.copy')}
              </CopyButton>
            </div>
          ) : null}
        </div>
        <Button variant="outline" size="sm" onClick={() => onOpenChange(false)}>
          {t('common.close')}
        </Button>
      </div>

      <div className="space-y-5">
        <div className="space-y-3">
          {steps.map((step, index) => (
            <div key={step} className="flex items-start gap-3">
              <Badge variant="secondary" className="min-w-8 justify-center">
                {index + 1}
              </Badge>
              <p className="text-sm text-foreground">{step}</p>
            </div>
          ))}
        </div>

        {verify.length > 0 ? (
          <div className="space-y-2">
            <p className="text-sm font-medium">{t('agents.guide.verify')}</p>
            <ul className="list-disc space-y-1 pl-5 text-sm text-muted-foreground">
              {verify.map((item) => (
                <li key={item}>{item}</li>
              ))}
            </ul>
          </div>
        ) : null}

        {configSnippet ? (
          <div className="space-y-2">
            <div className="flex items-center justify-between gap-2">
              <p className="text-sm font-medium">
                {t('agents.guide.configSnippet')}
              </p>
              <CopyButton
                value={configSnippet}
                variant="ghost"
                size="sm"
                successMessage={t('agents.actions.copied')}
              >
                {t('agents.actions.copy')}
              </CopyButton>
            </div>
            <pre className="overflow-x-auto rounded-md border border-border/70 bg-muted/30 p-3 text-xs">
              {configSnippet}
            </pre>
          </div>
        ) : null}

        {envSnippet ? (
          <div className="space-y-2">
            <div className="flex items-center justify-between gap-2">
              <p className="text-sm font-medium">
                {t('agents.guide.envSnippet')}
              </p>
              <CopyButton
                value={envSnippet}
                variant="ghost"
                size="sm"
                successMessage={t('agents.actions.copied')}
              >
                {t('agents.actions.copy')}
              </CopyButton>
            </div>
            <pre className="overflow-x-auto rounded-md border border-border/70 bg-muted/30 p-3 text-xs">
              {envSnippet}
            </pre>
          </div>
        ) : null}

        {caveats.length > 0 ? (
          <div className="space-y-2">
            <p className="text-sm font-medium">{t('agents.guide.caveats')}</p>
            <div className="flex flex-wrap gap-2">
              {caveats.map((item) => (
                <Badge key={item} variant="outline">
                  {item}
                </Badge>
              ))}
            </div>
          </div>
        ) : null}
      </div>
    </Panel>
  );
}
