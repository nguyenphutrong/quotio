import { requireAuth, requireScreenFeature } from './auth-guard';

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
      language: 'en-US',
    } as Navigator,
  });
}

function assertDoesNotThrow(action: () => void, message: string) {
  try {
    action();
  } catch (error) {
    throw new Error(`${message}: ${String(error)}`);
  }
}

function assertRedirectsTo(action: () => void, to: string, message: string) {
  try {
    action();
  } catch (error) {
    if (
      typeof error === 'object' &&
      error !== null &&
      'options' in error &&
      (error as { options?: { to?: unknown } }).options?.to === to
    ) {
      return;
    }
    throw new Error(`${message}: expected redirect to ${to}`);
  }

  throw new Error(`${message}: expected redirect to ${to}`);
}

setBootstrap({
  capabilities: {
    supportsManagementBridge: true,
  },
});
assertDoesNotThrow(
  () => requireScreenFeature('overview'),
  'authenticated management routes should load',
);

setBootstrap({
  capabilities: {
    supportsManagementBridge: false,
  },
});
assertRedirectsTo(
  () => requireAuth(),
  '/settings',
  'disconnected shell should land on settings',
);
assertRedirectsTo(
  () => requireScreenFeature('overview'),
  '/settings',
  'disconnected management routes should land on settings',
);
assertDoesNotThrow(
  () => requireScreenFeature('settings'),
  'disconnected settings should remain available',
);

setBootstrap({
  capabilities: {
    supportsManagementBridge: false,
  },
  features: {
    settings: false,
    about: true,
  },
});
assertRedirectsTo(
  () => requireScreenFeature('quota'),
  '/about',
  'disconnected shell should fall back to about when settings is disabled',
);
