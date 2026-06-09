import { RiLinksLine } from '@remixicon/react';
import { useTranslation } from 'react-i18next';
import { CopyButton } from '@/components/admin/copy-button';
import { useAdminRuntime } from '@/lib/admin/runtime';

const WILDCARD_HOSTS = ['', '0.0.0.0', '[::]', '[::0]'];

/**
 * Build the OpenAI-compatible gateway URL from Go's `server.listen` spec
 * (e.g. `:8387`, `127.0.0.1:8387`, `[::1]:8387`). Host falls back to the
 * current page when the config binds a wildcard or we can't parse it, so the
 * URL stays correct under the Vite dev server too.
 */
function buildGatewayUrl(serverListen: string): string {
  const match = serverListen.trim().match(/^(\[[^\]]+\]|[^:]*):(\d+)$/);
  const cfgHost = match?.[1] ?? '';
  const cfgPort = match?.[2] ?? '';

  const host = WILDCARD_HOSTS.includes(cfgHost)
    ? window.location.hostname
    : cfgHost;
  const port = cfgPort || window.location.port;
  const authority = port ? `${host}:${port}` : host;

  return `${window.location.protocol}//${authority}/v1`;
}

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
