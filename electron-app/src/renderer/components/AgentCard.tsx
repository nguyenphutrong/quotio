import type { CLIAgent } from '@shared/types';

interface AgentCardProps {
  agent: CLIAgent;
  onConfigure: (agent: CLIAgent) => void;
}

export default function AgentCard({ agent, onConfigure }: AgentCardProps): JSX.Element {
  return (
    <div className="bg-white dark:bg-gray-800 rounded-xl p-4 shadow-sm border border-gray-200 dark:border-gray-700">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="w-12 h-12 rounded-lg bg-gray-100 dark:bg-gray-700 flex items-center justify-center text-2xl">
            🤖
          </div>
          <div>
            <h3 className="font-semibold text-gray-900 dark:text-white">{agent.name}</h3>
            <div className="flex items-center gap-2 mt-1">
              <span
                className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-medium ${
                  agent.isInstalled
                    ? 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400'
                    : 'bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-400'
                }`}
              >
                {agent.isInstalled ? 'Installed' : 'Not Installed'}
              </span>
              {agent.version && (
                <span className="text-xs text-gray-500 dark:text-gray-400">
                  v{agent.version}
                </span>
              )}
            </div>
          </div>
        </div>

        <div className="flex items-center gap-2">
          {agent.isConfigured ? (
            <span className="inline-flex items-center px-3 py-1 rounded-lg text-sm font-medium bg-primary-100 text-primary-800 dark:bg-primary-900/30 dark:text-primary-400">
              Configured
            </span>
          ) : agent.isInstalled ? (
            <button
              onClick={() => onConfigure(agent)}
              className="px-4 py-2 bg-primary-500 hover:bg-primary-600 text-white rounded-lg text-sm font-medium transition-colors"
            >
              Configure
            </button>
          ) : (
            <span className="text-sm text-gray-400">Not available</span>
          )}
        </div>
      </div>

      {agent.configPath && agent.isConfigured && (
        <div className="mt-3 p-2 bg-gray-50 dark:bg-gray-900 rounded-lg">
          <p className="text-xs text-gray-500 dark:text-gray-400 font-mono truncate">
            {agent.configPath}
          </p>
        </div>
      )}
    </div>
  );
}
