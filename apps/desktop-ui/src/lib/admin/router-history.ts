import {
  createBrowserHistory,
  createHashHistory,
} from '@tanstack/react-router';

export function getDesktopRouterHistoryKind(protocol: string) {
  return protocol === 'file:' ? 'hash' : 'browser';
}

export function createDesktopRouterHistory() {
  return getDesktopRouterHistoryKind(window.location.protocol) === 'hash'
    ? createHashHistory()
    : createBrowserHistory();
}
