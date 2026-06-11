import { getDesktopRouterHistoryKind } from './router-history';

function assertEqual<T>(actual: T, expected: T, message: string) {
  if (actual !== expected) {
    throw new Error(`${message}: expected ${expected}, got ${actual}`);
  }
}

assertEqual(
  getDesktopRouterHistoryKind('file:'),
  'hash',
  'bundled desktop UI should ignore the index file path',
);

assertEqual(
  getDesktopRouterHistoryKind('http:'),
  'browser',
  'development server should preserve browser routing',
);

assertEqual(
  getDesktopRouterHistoryKind('https:'),
  'browser',
  'hosted desktop UI should preserve browser routing',
);
