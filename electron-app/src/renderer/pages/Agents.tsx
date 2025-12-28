import { useState } from 'react';
import { useApp } from '../store/AppContext';
import AgentCard from '../components/AgentCard';
import type { CLIAgent } from '@shared/types';

export default function Agents(): JSX.Element {
  const { state, actions } = useApp();
  const { agents, proxyStatus, isLoading } = state;
  const [configuringAgent, setConfiguringAgent] = useState<CLIAgent | null>(null);
  const [isConfiguring, setIsConfiguring] = useState(false);

  const installedAgents = agents.filter(a => a.isInstalled);
  const configuredAgents = agents.filter(a => a.isConfigured);

  const handleConfigure = async (agent: CLIAgent): Promise<void> => {
    setConfiguringAgent(agent);
  };

  const confirmConfigure = async (): Promise<void> => {
    if (!configuringAgent) return;

    setIsConfiguring(true);
    try {
      await window.electron.agent.configure({ agentId: configuringAgent.id });
      await actions.detectAgents();
      setConfiguringAgent(null);
    } catch (error) {
      console.error('Failed to configure agent:', error);
    } finally {
      setIsConfiguring(false);
    }
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white">CLI Agents</h1>
          <p className="text-gray-500 dark:text-gray-400">
            Detect and configure AI coding assistants to use Quotio proxy
          </p>
        </div>
        <button
          onClick={() => void actions.detectAgents()}
          disabled={isLoading}
          className="px-4 py-2 bg-primary-500 hover:bg-primary-600 disabled:opacity-50 text-white rounded-lg text-sm font-medium transition-colors flex items-center gap-2"
        >
          {isLoading && (
            <div className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin" />
          )}
          Scan for Agents
        </button>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div className="bg-white dark:bg-gray-800 rounded-xl p-4 shadow-sm border border-gray-200 dark:border-gray-700">
          <span className="text-sm text-gray-500 dark:text-gray-400">Detected Agents</span>
          <p className="text-3xl font-bold text-gray-900 dark:text-white mt-2">
            {installedAgents.length}
          </p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-xl p-4 shadow-sm border border-gray-200 dark:border-gray-700">
          <span className="text-sm text-gray-500 dark:text-gray-400">Configured</span>
          <p className="text-3xl font-bold text-green-600 dark:text-green-400 mt-2">
            {configuredAgents.length}
          </p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-xl p-4 shadow-sm border border-gray-200 dark:border-gray-700">
          <span className="text-sm text-gray-500 dark:text-gray-400">Proxy Status</span>
          <p className={`text-3xl font-bold mt-2 ${proxyStatus.isRunning ? 'text-green-600 dark:text-green-400' : 'text-gray-400'}`}>
            {proxyStatus.isRunning ? 'Ready' : 'Offline'}
          </p>
        </div>
      </div>

      {/* Warning if proxy not running */}
      {!proxyStatus.isRunning && (
        <div className="bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-xl p-4">
          <div className="flex items-center gap-2">
            <span className="text-yellow-600 dark:text-yellow-400 text-xl">⚠️</span>
            <p className="text-yellow-700 dark:text-yellow-300">
              Start the proxy before configuring agents. Agents need the proxy URL and API key.
            </p>
          </div>
        </div>
      )}

      {/* Agents List */}
      <div>
        <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">
          Available Agents
        </h2>
        {agents.length > 0 ? (
          <div className="space-y-4">
            {agents.map((agent) => (
              <AgentCard
                key={agent.id}
                agent={agent}
                onConfigure={handleConfigure}
              />
            ))}
          </div>
        ) : (
          <div className="bg-white dark:bg-gray-800 rounded-xl p-8 text-center border border-gray-200 dark:border-gray-700">
            <div className="text-4xl mb-4">🔍</div>
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-2">
              No Agents Detected
            </h3>
            <p className="text-gray-500 dark:text-gray-400 max-w-md mx-auto">
              Click "Scan for Agents" to detect installed CLI AI assistants like Claude Code, Codex CLI, or Gemini CLI.
            </p>
          </div>
        )}
      </div>

      {/* Configuration Modal */}
      {configuringAgent && (
        <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
          <div className="bg-white dark:bg-gray-800 rounded-xl p-6 max-w-md w-full mx-4 shadow-xl">
            <h2 className="text-xl font-bold text-gray-900 dark:text-white mb-4">
              Configure {configuringAgent.name}
            </h2>

            <div className="space-y-4">
              <p className="text-gray-600 dark:text-gray-400">
                This will configure {configuringAgent.name} to use the Quotio proxy for all API requests.
              </p>

              <div className="p-3 bg-gray-50 dark:bg-gray-900 rounded-lg">
                <p className="text-sm text-gray-600 dark:text-gray-400">
                  <strong>Proxy URL:</strong> http://127.0.0.1:{proxyStatus.port}
                </p>
                <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
                  <strong>Config Path:</strong> {configuringAgent.configPath || 'Auto-detected'}
                </p>
              </div>

              <div className="flex gap-3 pt-4">
                <button
                  onClick={() => setConfiguringAgent(null)}
                  className="flex-1 py-2 bg-gray-100 hover:bg-gray-200 dark:bg-gray-700 dark:hover:bg-gray-600 text-gray-700 dark:text-gray-300 rounded-lg font-medium transition-colors"
                >
                  Cancel
                </button>
                <button
                  onClick={() => void confirmConfigure()}
                  disabled={isConfiguring || !proxyStatus.isRunning}
                  className="flex-1 py-2 bg-primary-500 hover:bg-primary-600 disabled:opacity-50 text-white rounded-lg font-medium transition-colors flex items-center justify-center gap-2"
                >
                  {isConfiguring && (
                    <div className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin" />
                  )}
                  Configure
                </button>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
