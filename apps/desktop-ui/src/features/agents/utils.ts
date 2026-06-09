export function safeArray<T>(value: unknown): T[] {
  return Array.isArray(value) ? value : [];
}

export function safeStr(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback;
}

export type AgentPlatformSupport =
  | 'supported'
  | 'guide-only'
  | 'unsupported'
  | 'unknown';

export function normalizeAgentPlatformSupport(
  value: unknown,
): AgentPlatformSupport | undefined {
  if (
    value === 'supported' ||
    value === 'guide-only' ||
    value === 'unsupported' ||
    value === 'unknown'
  ) {
    return value;
  }
  return undefined;
}
