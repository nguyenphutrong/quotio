import { buildGatewayUrl } from './gateway-url';

function assertEqual(actual: string, expected: string, message: string) {
  if (actual !== expected) {
    throw new Error(`${message}: expected ${expected}, got ${actual}`);
  }
}

assertEqual(
  buildGatewayUrl('127.0.0.1:8387', {
    protocol: 'file:',
    hostname: '',
    port: '',
  }),
  'http://127.0.0.1:8387/v1',
  'bundled file URL should still produce an HTTP gateway URL',
);

assertEqual(
  buildGatewayUrl(':8387', {
    protocol: 'file:',
    hostname: '',
    port: '',
  }),
  'http://127.0.0.1:8387/v1',
  'wildcard bundled host should fall back to loopback',
);

assertEqual(
  buildGatewayUrl(':8387', {
    protocol: 'https:',
    hostname: 'dev.example',
    port: '5173',
  }),
  'https://dev.example:8387/v1',
  'dev server wildcard should preserve the page host',
);

assertEqual(
  buildGatewayUrl('[::1]:8387', {
    protocol: 'http:',
    hostname: 'localhost',
    port: '5173',
  }),
  'http://[::1]:8387/v1',
  'IPv6 listen host should stay bracketed',
);
