import { Outlet, NavLink } from 'react-router-dom';
import { useApp } from '../store/AppContext';

const navItems = [
  { path: '/dashboard', label: 'Dashboard', icon: '📊' },
  { path: '/quotas', label: 'Quotas', icon: '📈' },
  { path: '/providers', label: 'Providers', icon: '🔗' },
  { path: '/agents', label: 'Agents', icon: '🤖' },
  { path: '/settings', label: 'Settings', icon: '⚙️' },
  { path: '/logs', label: 'Logs', icon: '📝' },
];

export default function Layout(): JSX.Element {
  const { state } = useApp();
  const { proxyStatus } = state;

  return (
    <div className="flex h-screen bg-gray-50 dark:bg-gray-900">
      {/* Sidebar */}
      <aside className="w-64 bg-white dark:bg-gray-800 border-r border-gray-200 dark:border-gray-700 flex flex-col">
        {/* Title bar drag region */}
        <div className="h-8 drag-region" />

        {/* Logo */}
        <div className="px-6 py-4 border-b border-gray-200 dark:border-gray-700">
          <h1 className="text-xl font-bold text-gray-900 dark:text-white">Quotio</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400">AI Assistant Manager</p>
        </div>

        {/* Proxy Status */}
        <div className="px-6 py-3 border-b border-gray-200 dark:border-gray-700">
          <div className="flex items-center gap-2">
            <div className={`status-dot ${proxyStatus.isRunning ? 'running' : 'stopped'}`} />
            <span className="text-sm text-gray-600 dark:text-gray-300">
              Proxy: {proxyStatus.isRunning ? `Running on :${proxyStatus.port}` : 'Stopped'}
            </span>
          </div>
          {proxyStatus.uptime !== undefined && proxyStatus.isRunning && (
            <p className="text-xs text-gray-400 mt-1">
              Uptime: {formatUptime(proxyStatus.uptime)}
            </p>
          )}
        </div>

        {/* Navigation */}
        <nav className="flex-1 px-4 py-4 space-y-1 overflow-y-auto">
          {navItems.map((item) => (
            <NavLink
              key={item.path}
              to={item.path}
              className={({ isActive }) =>
                `flex items-center gap-3 px-3 py-2 rounded-lg transition-colors no-drag ${
                  isActive
                    ? 'bg-primary-50 dark:bg-primary-900/50 text-primary-600 dark:text-primary-400'
                    : 'text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700'
                }`
              }
            >
              <span>{item.icon}</span>
              <span className="font-medium">{item.label}</span>
            </NavLink>
          ))}
        </nav>

        {/* Version */}
        <div className="px-6 py-3 border-t border-gray-200 dark:border-gray-700">
          <p className="text-xs text-gray-400">v1.0.0 (Electron)</p>
        </div>
      </aside>

      {/* Main Content */}
      <main className="flex-1 flex flex-col overflow-hidden">
        {/* Title bar drag region */}
        <div className="h-8 drag-region bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700" />

        {/* Page Content */}
        <div className="flex-1 overflow-auto p-6">
          <Outlet />
        </div>
      </main>
    </div>
  );
}

function formatUptime(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = seconds % 60;

  if (hours > 0) {
    return `${hours}h ${minutes}m`;
  }
  if (minutes > 0) {
    return `${minutes}m ${secs}s`;
  }
  return `${secs}s`;
}
