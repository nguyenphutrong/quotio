import { getDesktopBootstrap } from './bootstrap';

function setBootstrap(payload: unknown) {
  Object.defineProperty(globalThis, 'window', {
    configurable: true,
    value: {
      __QUOTIO_DESKTOP_BOOTSTRAP__: payload,
    } as Window,
  });
  Object.defineProperty(globalThis, 'navigator', {
    configurable: true,
    value: {
      language: 'vi-VN',
    } as Navigator,
  });
}

function assertEqual<T>(actual: T, expected: T, message: string) {
  if (actual !== expected) {
    throw new Error(`${message}: expected ${expected}, got ${actual}`);
  }
}

setBootstrap({
  appearance: 'dark',
  locale: 'en-US',
  uiEnabled: true,
});
assertEqual(
  getDesktopBootstrap().appearance,
  'dark',
  'bootstrap should preserve a valid host appearance',
);

setBootstrap({
  appearance: 'sepia',
  uiEnabled: true,
});
assertEqual(
  getDesktopBootstrap().appearance,
  'system',
  'bootstrap should normalize an invalid host appearance',
);

setBootstrap(undefined);
assertEqual(
  getDesktopBootstrap().appearance,
  'system',
  'bootstrap should default missing appearance to system',
);

setBootstrap({
  capabilities: {
    supportsManagementBridge: true,
  },
});
assertEqual(
  getDesktopBootstrap().authStatus,
  'authenticated',
  'bootstrap should authenticate when the management bridge is ready',
);

setBootstrap({
  capabilities: {
    supportsManagementBridge: false,
  },
});
assertEqual(
  getDesktopBootstrap().authStatus,
  'disconnected',
  'bootstrap should disconnect when the management bridge is unavailable',
);

setBootstrap({
  authStatus: 'disconnected',
  capabilities: {
    supportsManagementBridge: true,
  },
});
assertEqual(
  getDesktopBootstrap().authStatus,
  'disconnected',
  'bootstrap should preserve a valid explicit host auth status',
);
