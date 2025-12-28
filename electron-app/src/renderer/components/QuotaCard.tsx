import type { QuotaInfo } from '@shared/types';
import { PROVIDER_CONFIG } from '@shared/constants';

interface QuotaCardProps {
  quota: QuotaInfo;
  showDetails?: boolean;
}

export default function QuotaCard({ quota, showDetails = false }: QuotaCardProps): JSX.Element {
  const config = PROVIDER_CONFIG[quota.providerType];
  const remaining = 100 - quota.percentage;

  const getStatusColor = (): string => {
    if (remaining > 50) return 'bg-green-500';
    if (remaining > 20) return 'bg-yellow-500';
    return 'bg-red-500';
  };

  const getStatusBg = (): string => {
    if (remaining > 50) return 'bg-green-100 dark:bg-green-900/30';
    if (remaining > 20) return 'bg-yellow-100 dark:bg-yellow-900/30';
    return 'bg-red-100 dark:bg-red-900/30';
  };

  return (
    <div className="bg-white dark:bg-gray-800 rounded-xl p-4 shadow-sm border border-gray-200 dark:border-gray-700 card-hover">
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-3">
          <div
            className="w-10 h-10 rounded-lg flex items-center justify-center text-white font-bold"
            style={{ backgroundColor: config?.color || '#6b7280' }}
          >
            {config?.name.charAt(0) || quota.providerType.charAt(0).toUpperCase()}
          </div>
          <div>
            <h3 className="font-semibold text-gray-900 dark:text-white">
              {config?.name || quota.providerType}
            </h3>
            <p className="text-sm text-gray-500 dark:text-gray-400">
              {quota.providerId}
            </p>
          </div>
        </div>
        <div className={`px-3 py-1 rounded-full text-sm font-medium ${getStatusBg()}`}>
          <span className={remaining <= 20 ? 'text-red-600 dark:text-red-400' : remaining <= 50 ? 'text-yellow-600 dark:text-yellow-400' : 'text-green-600 dark:text-green-400'}>
            {remaining.toFixed(0)}% left
          </span>
        </div>
      </div>

      {/* Progress Bar */}
      <div className="h-2 bg-gray-200 dark:bg-gray-700 rounded-full overflow-hidden">
        <div
          className={`h-full transition-all duration-500 ${getStatusColor()}`}
          style={{ width: `${quota.percentage}%` }}
        />
      </div>

      <div className="flex justify-between mt-2 text-sm text-gray-500 dark:text-gray-400">
        <span>Used: {quota.used}</span>
        <span>Total: {quota.total}</span>
      </div>

      {showDetails && quota.models && quota.models.length > 0 && (
        <div className="mt-4 pt-4 border-t border-gray-200 dark:border-gray-700">
          <h4 className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
            Models
          </h4>
          <div className="space-y-2">
            {quota.models.map((model) => (
              <div key={model.modelId} className="flex items-center justify-between">
                <span className="text-sm text-gray-600 dark:text-gray-400">
                  {model.modelName}
                </span>
                <span className="text-sm font-medium text-gray-900 dark:text-white">
                  {(100 - model.percentage).toFixed(0)}%
                </span>
              </div>
            ))}
          </div>
        </div>
      )}

      {quota.resetDate && (
        <p className="mt-3 text-xs text-gray-400">
          Resets: {new Date(quota.resetDate).toLocaleDateString()}
        </p>
      )}
    </div>
  );
}
