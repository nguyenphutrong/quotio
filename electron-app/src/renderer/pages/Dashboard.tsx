import { useApp } from '../store/AppContext';
import QuotaCard from '../components/QuotaCard';

export default function Dashboard(): JSX.Element {
  const { state, actions } = useApp();
  const { proxyStatus, quotas, stats, isLoading } = state;

  const handleProxyToggle = async (): Promise<void> => {
    if (proxyStatus.isRunning) {
      await actions.stopProxy();
    } else {
      await actions.startProxy();
    }
  };

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-full">
        <div className="w-8 h-8 border-4 border-primary-500 border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Dashboard</h1>
          <p className="text-gray-500 dark:text-gray-400">
            Overview of your AI assistant quotas and proxy status
          </p>
        </div>
        <button
          onClick={() => void actions.refreshQuotas()}
          className="px-4 py-2 bg-gray-100 dark:bg-gray-700 hover:bg-gray-200 dark:hover:bg-gray-600 rounded-lg text-sm font-medium transition-colors"
        >
          Refresh
        </button>
      </div>

      {/* Stats Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
        {/* Proxy Status */}
        <div className="bg-white dark:bg-gray-800 rounded-xl p-4 shadow-sm border border-gray-200 dark:border-gray-700">
          <div className="flex items-center justify-between mb-2">
            <span className="text-sm text-gray-500 dark:text-gray-400">Proxy Status</span>
            <div className={`status-dot ${proxyStatus.isRunning ? 'running' : 'stopped'}`} />
          </div>
          <p className="text-2xl font-bold text-gray-900 dark:text-white">
            {proxyStatus.isRunning ? 'Online' : 'Offline'}
          </p>
          <button
            onClick={() => void handleProxyToggle()}
            className={`mt-3 w-full py-2 rounded-lg text-sm font-medium transition-colors ${
              proxyStatus.isRunning
                ? 'bg-red-100 text-red-600 hover:bg-red-200 dark:bg-red-900/30 dark:text-red-400'
                : 'bg-green-100 text-green-600 hover:bg-green-200 dark:bg-green-900/30 dark:text-green-400'
            }`}
          >
            {proxyStatus.isRunning ? 'Stop Proxy' : 'Start Proxy'}
          </button>
        </div>

        {/* Total Requests */}
        <div className="bg-white dark:bg-gray-800 rounded-xl p-4 shadow-sm border border-gray-200 dark:border-gray-700">
          <span className="text-sm text-gray-500 dark:text-gray-400">Total Requests</span>
          <p className="text-2xl font-bold text-gray-900 dark:text-white mt-2">
            {stats?.totalRequests?.toLocaleString() || proxyStatus.requestCount.toLocaleString()}
          </p>
          <p className="text-sm text-gray-400 mt-1">
            {stats?.successfulRequests || 0} successful
          </p>
        </div>

        {/* Error Rate */}
        <div className="bg-white dark:bg-gray-800 rounded-xl p-4 shadow-sm border border-gray-200 dark:border-gray-700">
          <span className="text-sm text-gray-500 dark:text-gray-400">Error Rate</span>
          <p className="text-2xl font-bold text-gray-900 dark:text-white mt-2">
            {stats?.totalRequests
              ? ((stats.failedRequests / stats.totalRequests) * 100).toFixed(1)
              : '0.0'}%
          </p>
          <p className="text-sm text-gray-400 mt-1">
            {stats?.failedRequests || proxyStatus.errorCount} errors
          </p>
        </div>

        {/* Active Providers */}
        <div className="bg-white dark:bg-gray-800 rounded-xl p-4 shadow-sm border border-gray-200 dark:border-gray-700">
          <span className="text-sm text-gray-500 dark:text-gray-400">Active Providers</span>
          <p className="text-2xl font-bold text-gray-900 dark:text-white mt-2">
            {quotas.length}
          </p>
          <p className="text-sm text-gray-400 mt-1">
            {quotas.filter(q => (100 - q.percentage) > 20).length} healthy
          </p>
        </div>
      </div>

      {/* Quotas Overview */}
      <div>
        <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
          Quota Overview
        </h2>
        {quotas.length > 0 ? (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            {quotas.map((quota) => (
              <QuotaCard key={quota.providerId} quota={quota} />
            ))}
          </div>
        ) : (
          <div className="bg-white dark:bg-gray-800 rounded-xl p-8 text-center border border-gray-200 dark:border-gray-700">
            <p className="text-gray-500 dark:text-gray-400">
              No quotas available. Add providers to see their quota information.
            </p>
          </div>
        )}
      </div>

      {/* Recent Activity (Placeholder) */}
      <div>
        <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
          Recent Activity
        </h2>
        <div className="bg-white dark:bg-gray-800 rounded-xl p-4 border border-gray-200 dark:border-gray-700">
          <div className="space-y-3">
            {[1, 2, 3].map((i) => (
              <div
                key={i}
                className="flex items-center gap-3 p-3 bg-gray-50 dark:bg-gray-900 rounded-lg"
              >
                <div className="w-2 h-2 bg-green-500 rounded-full" />
                <span className="text-sm text-gray-600 dark:text-gray-300">
                  Request to Claude API - 200 OK
                </span>
                <span className="text-xs text-gray-400 ml-auto">Just now</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
