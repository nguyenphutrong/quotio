import { redirect } from '@tanstack/react-router';
import {
  getDesktopBootstrap,
  getFirstEnabledRoute,
  type ScreenFeatureKey,
} from '@/lib/admin/bootstrap';

export function requireAuth() {
  return;
}

export function requireScreenFeature(feature: ScreenFeatureKey) {
  requireAuth();

  const bootstrap = getDesktopBootstrap();

  if (bootstrap.features[feature]) {
    return;
  }

  throw redirect({ to: getFirstEnabledRoute(bootstrap.features) });
}
