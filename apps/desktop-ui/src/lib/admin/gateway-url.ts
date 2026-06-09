const WILDCARD_HOSTS = ['', '0.0.0.0', '[::]', '[::0]'];

type GatewayLocation = Pick<Location, 'protocol' | 'hostname' | 'port'>;

function normalizeGatewayProtocol(protocol: string) {
  return protocol === 'https:' ? 'https:' : 'http:';
}

function normalizeGatewayHost(host: string, location: GatewayLocation) {
  if (!WILDCARD_HOSTS.includes(host)) {
    return host;
  }

  return location.hostname || '127.0.0.1';
}

/**
 * Build the OpenAI-compatible gateway URL from Go's `server.listen` spec
 * (e.g. `:8387`, `127.0.0.1:8387`, `[::1]:8387`). Bundled native hosts load
 * from `file:`, so the gateway scheme must come from the proxy, not the page.
 */
export function buildGatewayUrl(
  serverListen: string,
  location: GatewayLocation = window.location,
): string {
  const match = serverListen.trim().match(/^(\[[^\]]+\]|[^:]*):(\d+)$/);
  const cfgHost = match?.[1] ?? '';
  const cfgPort = match?.[2] ?? '';

  const protocol = normalizeGatewayProtocol(location.protocol);
  const host = normalizeGatewayHost(cfgHost, location);
  const port = cfgPort || location.port;
  const authority = port ? `${host}:${port}` : host;

  return `${protocol}//${authority}/v1`;
}
