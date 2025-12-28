import { useApp } from '../store/AppContext';
import QuotaCard from '../components/QuotaCard';

export default function Quotas(): JSX.Element {
  const { state, actions } = useApp();
  const { quotas, isLoading } = state;

  const totalRemaining = quotas.length > 0
    ? quotas.reduce((sum, q) => sum + (100 - q.percentage), 0) / quotas.length
    : 0;

  const lowQuotas = quotas.filter(q => (100 - q.percentage) <= 20);
  const healthyQuotas = quotas.filter(q => (100 - q.percentage) > 20);

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Quota Management</h1>
          <p className="text-gray-500 dark:text-gray-400">
            Monitor and manage your AI provider quotas
          </p>
        </div>
        <button
          onClick={() => void actions.refreshQuotas()}
          disabled={isLoading}
          className="px-4 py-2 bg-primary-500 hover:bg-primary-600 disabled:opacity-50 text-white rounded-lg text-sm font-medium transition-colors flex items-center gap-2"
        >
          {isLoading && (
            <div className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin" />
          )}
          Refresh All
        </button>
      </div>

      {/* Summary */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div className="bg-white dark:bg-gray-800 rounded-xl p-4 shadow-sm border border-gray-200 dark:border-gray-700">
          <span className="text-sm text-gray-500 dark:text-gray-400">Average Remaining</span>
          <p className="text-3xl font-bold text-gray-900 dark:text-white mt-2">
            {totalRemaining.toFixed(0)}%
          </p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-xl p-4 shadow-sm border border-gray-200 dark:border-gray-700">
          <span className="text-sm text-gray-500 dark:text-gray-400">Healthy Providers</span>
          <p className="text-3xl font-bold text-green-600 dark:text-green-400 mt-2">
            {healthyQuotas.length}
          </p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-xl p-4 shadow-sm border border-gray-200 dark:border-gray-700">
          <span className="text-sm text-gray-500 dark:text-gray-400">Low Quota Alerts</span>
          <p className="text-3xl font-bold text-red-600 dark:text-red-400 mt-2">
            {lowQuotas.length}
          </p>
        </div>
      </div>

      {/* Low Quota Warnings */}
      {lowQuotas.length > 0 && (
        <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-xl p-4">
          <div className="flex items-center gap-2 mb-3">
            <span className="text-red-600 dark:text-red-400 text-xl">⚠️</span>
            <h2 className="text-lg font-semibold text-red-800 dark:text-red-200">
              Low Quota Warning
            </h2>
          </div>
          <p className="text-red-700 dark:text-red-300 text-sm mb-4">
            The following providers have less than 20% quota remaining:
          </p>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            {lowQuotas.map((quota) => (
              <QuotaCard key={quota.providerId} quota={quota} showDetails />
            ))}
          </div>
        </div>
      )}

      {/* All Quotas */}
      <div>
        <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
          All Providers
        </h2>
        {quotas.length > 0 ? (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            {quotas.map((quota) => (
              <QuotaCard key={quota.providerId} quota={quota} showDetails />
            ))}
          </div>
        ) : (
          <div className="bg-white dark:bg-gray-800 rounded-xl p-8 text-center border border-gray-200 dark:border-gray-700">
            <div className="text-4xl mb-4">📊</div>
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-2">
              No Quotas Found
            </h3>
            <p className="text-gray-500 dark:text-gray-400 max-w-md mx-auto">
              Add AI provider accounts to start tracking their quotas. Go to the Providers page to add new accounts.
            </p>
          </div>
        )}
      </div>
    </div>
  );
}
