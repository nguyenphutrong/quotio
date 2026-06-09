export function safeArray<T>(value: unknown): T[] {
  return Array.isArray(value) ? value : [];
}

export function safeStr(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback;
}
