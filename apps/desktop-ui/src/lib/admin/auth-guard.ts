import { redirect } from '@tanstack/react-router';
import {
  getDesktopBootstrap,
  getFirstEnabledRoute,
  type ScreenFeatureKey,
} from '@/lib/admin/bootstrap';

const PUBLIC_FEATURES = new Set<ScreenFeatureKey>(['settings', 'about']);

function getDisconnectedRoute(features: Record<ScreenFeatureKey, boolean>) {
  if (features.settings) {
    return '/settings';
  }
  if (features.about) {
    return '/about';
  }
  return getFirstEnabledRoute(features);
}

export function requireAuth(feature?: ScreenFeatureKey) {
  const bootstrap = getDesktopBootstrap();

  if (bootstrap.authStatus === 'authenticated') {
    return;
  }

  if (feature && PUBLIC_FEATURES.has(feature)) {
    return;
  }

  throw redirect({ to: getDisconnectedRoute(bootstrap.features) });
}

export function requireScreenFeature(feature: ScreenFeatureKey) {
  const bootstrap = getDesktopBootstrap();

  if (bootstrap.features[feature]) {
    requireAuth(feature);
    return;
  }

  throw redirect({ to: getFirstEnabledRoute(bootstrap.features) });
}
