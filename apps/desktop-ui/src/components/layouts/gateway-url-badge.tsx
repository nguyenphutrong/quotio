import { RiLinksLine } from '@remixicon/react';
import { useTranslation } from 'react-i18next';
import { CopyButton } from '@/components/admin/copy-button';
import { buildGatewayUrl } from '@/lib/admin/gateway-url';
import { useAdminRuntime } from '@/lib/admin/runtime';

export function GatewayUrlBadge() {
  const { t } = useTranslation();
  const { bootstrap } = useAdminRuntime();
  const url = buildGatewayUrl(bootstrap.serverListen);

  return (
    <div
      className="flex min-w-0 items-center gap-1 rounded-full border border-border bg-muted/60 py-0.5 pl-2.5 pr-0.5"
      title={t('shell.gatewayUrlHint')}
    >
      <RiLinksLine
        aria-hidden
        className="size-3.5 shrink-0 text-muted-foreground"
      />
      <span className="sr-only">{t('shell.gatewayUrl')}</span>
      <code className="truncate font-mono text-xs text-foreground">{url}</code>
      <CopyButton
        value={url}
        variant="ghost"
        size="icon-xs"
        className="rounded-full text-muted-foreground hover:text-foreground"
        aria-label={t('shell.copyGatewayUrl')}
        title={t('shell.copyGatewayUrl')}
        successMessage={t('shell.gatewayUrlCopied')}
      />
    </div>
  );
}
