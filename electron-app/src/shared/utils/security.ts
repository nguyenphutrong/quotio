// ============================================
// Quotio - Security Utilities
// ============================================

import { SECURITY } from '../constants';

/**
 * Validates if a URL is safe to open externally
 * Prevents open redirect vulnerabilities
 */
export function isValidExternalUrl(url: string): boolean {
  try {
    const parsed = new URL(url);

    // Only allow HTTPS
    if (parsed.protocol !== 'https:') {
      return false;
    }

    // Check against allowed domains
    const isAllowed = SECURITY.ALLOWED_EXTERNAL_DOMAINS.some(domain =>
      parsed.hostname === domain || parsed.hostname.endsWith(`.${domain}`)
    );

    return isAllowed;
  } catch {
    return false;
  }
}

/**
 * Sanitizes user input to prevent XSS
 */
export function sanitizeInput(input: string): string {
  return input
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#x27;')
    .replace(/\//g, '&#x2F;');
}

/**
 * Validates file path to prevent path traversal attacks
 */
export function isValidFilePath(path: string, baseDir: string): boolean {
  const normalizedPath = path.replace(/\\/g, '/');
  const normalizedBase = baseDir.replace(/\\/g, '/');

  // Check for path traversal attempts
  if (normalizedPath.includes('..') || normalizedPath.includes('//')) {
    return false;
  }

  // Ensure path starts with base directory
  if (!normalizedPath.startsWith(normalizedBase)) {
    return false;
  }

  return true;
}

/**
 * Generates a cryptographically secure random string
 */
export function generateSecureToken(length: number = 32): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  const array = new Uint8Array(length);
  crypto.getRandomValues(array);

  return Array.from(array, byte => chars[byte % chars.length]).join('');
}

/**
 * Validates API key format
 */
export function isValidApiKey(key: string): boolean {
  // API keys should be alphanumeric with optional dashes/underscores
  const pattern = /^[A-Za-z0-9_-]{20,128}$/;
  return pattern.test(key);
}

/**
 * Masks sensitive data for logging
 */
export function maskSensitiveData(data: string, visibleChars: number = 4): string {
  if (data.length <= visibleChars * 2) {
    return '*'.repeat(data.length);
  }

  const start = data.slice(0, visibleChars);
  const end = data.slice(-visibleChars);
  const masked = '*'.repeat(Math.min(data.length - visibleChars * 2, 20));

  return `${start}${masked}${end}`;
}

/**
 * Validates JSON structure to prevent prototype pollution
 */
export function safeJsonParse<T>(json: string): T | null {
  try {
    const parsed = JSON.parse(json) as T;

    // Check for prototype pollution attempts
    if (typeof parsed === 'object' && parsed !== null) {
      const dangerous = ['__proto__', 'constructor', 'prototype'];
      const checkObject = (obj: Record<string, unknown>): boolean => {
        for (const key of Object.keys(obj)) {
          if (dangerous.includes(key)) {
            return false;
          }
          if (typeof obj[key] === 'object' && obj[key] !== null) {
            if (!checkObject(obj[key] as Record<string, unknown>)) {
              return false;
            }
          }
        }
        return true;
      };

      if (!checkObject(parsed as Record<string, unknown>)) {
        return null;
      }
    }

    return parsed;
  } catch {
    return null;
  }
}

/**
 * Rate limiter implementation
 */
export class RateLimiter {
  private requests: Map<string, number[]> = new Map();

  constructor(
    private maxRequests: number,
    private windowMs: number
  ) {}

  isAllowed(key: string): boolean {
    const now = Date.now();
    const windowStart = now - this.windowMs;

    let timestamps = this.requests.get(key) || [];

    // Remove old timestamps
    timestamps = timestamps.filter(t => t > windowStart);

    if (timestamps.length >= this.maxRequests) {
      return false;
    }

    timestamps.push(now);
    this.requests.set(key, timestamps);

    return true;
  }

  reset(key: string): void {
    this.requests.delete(key);
  }

  clear(): void {
    this.requests.clear();
  }
}

/**
 * Validates IPC channel name to prevent injection
 */
export function isValidIPCChannel(channel: string): boolean {
  // Only allow quotio-prefixed channels
  return /^quotio:[a-z:-]+$/.test(channel);
}

/**
 * Deep freeze object to prevent modification
 */
export function deepFreeze<T extends object>(obj: T): Readonly<T> {
  Object.keys(obj).forEach(key => {
    const value = (obj as Record<string, unknown>)[key];
    if (typeof value === 'object' && value !== null) {
      deepFreeze(value as object);
    }
  });

  return Object.freeze(obj);
}
