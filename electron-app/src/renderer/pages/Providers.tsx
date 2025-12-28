import { useState } from 'react';
import { useApp } from '../store/AppContext';
import { PROVIDER_CONFIG } from '@shared/constants';
import type { AIProviderType } from '@shared/types';

export default function Providers(): JSX.Element {
  const { state } = useApp();
  const { quotas } = state;
  const [selectedProvider, setSelectedProvider] = useState<AIProviderType | null>(null);

  const providers = Object.entries(PROVIDER_CONFIG) as [AIProviderType, typeof PROVIDER_CONFIG[AIProviderType]][];

  const getProviderStatus = (providerType: AIProviderType): 'connected' | 'disconnected' => {
    return quotas.some(q => q.providerType === providerType) ? 'connected' : 'disconnected';
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div>
        <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Providers</h1>
        <p className="text-gray-500 dark:text-gray-400">
          Connect and manage your AI provider accounts
        </p>
      </div>

      {/* Provider Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {providers.map(([type, config]) => {
          const status = getProviderStatus(type);
          const isConnected = status === 'connected';

          return (
            <div
              key={type}
              className={`bg-white dark:bg-gray-800 rounded-xl p-4 shadow-sm border-2 transition-all cursor-pointer card-hover ${
                isConnected
                  ? 'border-green-200 dark:border-green-800'
                  : 'border-gray-200 dark:border-gray-700'
              }`}
              onClick={() => setSelectedProvider(type)}
            >
              <div className="flex items-center gap-3 mb-3">
                <div
                  className="w-12 h-12 rounded-lg flex items-center justify-center text-white text-xl font-bold"
                  style={{ backgroundColor: config.color }}
                >
                  {config.name.charAt(0)}
                </div>
                <div>
                  <h3 className="font-semibold text-gray-900 dark:text-white">
                    {config.name}
                  </h3>
                  <span
                    className={`text-xs px-2 py-0.5 rounded-full ${
                      isConnected
                        ? 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'
                        : 'bg-gray-100 text-gray-600 dark:bg-gray-700 dark:text-gray-400'
                    }`}
                  >
                    {isConnected ? 'Connected' : 'Not Connected'}
                  </span>
                </div>
              </div>

              <div className="flex items-center justify-between text-sm">
                <span className="text-gray-500 dark:text-gray-400">
                  Auth: {config.authMethod}
                </span>
                <button
                  className={`px-3 py-1 rounded-lg text-sm font-medium transition-colors ${
                    isConnected
                      ? 'bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-300'
                      : 'bg-primary-100 text-primary-600 hover:bg-primary-200 dark:bg-primary-900/30 dark:text-primary-400'
                  }`}
                  onClick={(e) => {
                    e.stopPropagation();
                    setSelectedProvider(type);
                  }}
                >
                  {isConnected ? 'Manage' : 'Connect'}
                </button>
              </div>
            </div>
          );
        })}
      </div>

      {/* Provider Detail Modal */}
      {selectedProvider && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
          <div className="bg-white dark:bg-gray-800 rounded-xl p-6 max-w-md w-full mx-4 shadow-xl">
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-xl font-bold text-gray-900 dark:text-white">
                {PROVIDER_CONFIG[selectedProvider].name}
              </h2>
              <button
                onClick={() => setSelectedProvider(null)}
                className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg"
              >
                ✕
              </button>
            </div>

            <div className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                  Authentication Method
                </label>
                <p className="text-gray-600 dark:text-gray-400">
                  {PROVIDER_CONFIG[selectedProvider].authMethod}
                </p>
              </div>

              <div>
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                  Auth File Pattern
                </label>
                <code className="block p-2 bg-gray-100 dark:bg-gray-900 rounded text-sm">
                  {PROVIDER_CONFIG[selectedProvider].authFilePattern}
                </code>
              </div>

              <div className="pt-4 border-t border-gray-200 dark:border-gray-700">
                <p className="text-sm text-gray-500 dark:text-gray-400 mb-4">
                  {PROVIDER_CONFIG[selectedProvider].authMethod === 'oauth'
                    ? 'Click the button below to authenticate with this provider via OAuth.'
                    : PROVIDER_CONFIG[selectedProvider].authMethod === 'cli'
                    ? 'Use the CLI tool to authenticate. The credentials will be automatically detected.'
                    : 'Add your service account JSON file to connect.'}
                </p>

                <button className="w-full py-2 bg-primary-500 hover:bg-primary-600 text-white rounded-lg font-medium transition-colors">
                  {getProviderStatus(selectedProvider) === 'connected'
                    ? 'Reconnect'
                    : 'Connect Account'}
                </button>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
