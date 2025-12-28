import { useState, useEffect } from 'react';
import type { LogEntry } from '@shared/types';

type LogLevel = 'all' | 'debug' | 'info' | 'warn' | 'error';

export default function Logs(): JSX.Element {
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [filter, setFilter] = useState<LogLevel>('all');
  const [isLoading, setIsLoading] = useState(true);

  const fetchLogs = async (): Promise<void> => {
    try {
      const fetchedLogs = await window.electron.logs.get();
      setLogs(fetchedLogs as LogEntry[]);
    } catch (error) {
      console.error('Failed to fetch logs:', error);
    } finally {
      setIsLoading(false);
    }
  };

  useEffect(() => {
    void fetchLogs();
    const interval = setInterval(() => void fetchLogs(), 5000);
    return () => clearInterval(interval);
  }, []);

  const handleClear = async (): Promise<void> => {
    await window.electron.logs.clear();
    setLogs([]);
  };

  const filteredLogs = filter === 'all'
    ? logs
    : logs.filter(log => log.level === filter);

  const getLevelColor = (level: string): string => {
    switch (level) {
      case 'error': return 'text-red-600 dark:text-red-400 bg-red-50 dark:bg-red-900/20';
      case 'warn': return 'text-yellow-600 dark:text-yellow-400 bg-yellow-50 dark:bg-yellow-900/20';
      case 'info': return 'text-blue-600 dark:text-blue-400 bg-blue-50 dark:bg-blue-900/20';
      case 'debug': return 'text-gray-600 dark:text-gray-400 bg-gray-50 dark:bg-gray-900/20';
      default: return 'text-gray-600 dark:text-gray-400';
    }
  };

  return (
    <div className="space-y-6 h-full flex flex-col">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Logs</h1>
          <p className="text-gray-500 dark:text-gray-400">
            View application and proxy logs
          </p>
        </div>
        <div className="flex items-center gap-3">
          <select
            value={filter}
            onChange={(e) => setFilter(e.target.value as LogLevel)}
            className="px-3 py-2 bg-gray-100 dark:bg-gray-700 border-0 rounded-lg text-gray-900 dark:text-white"
          >
            <option value="all">All Levels</option>
            <option value="debug">Debug</option>
            <option value="info">Info</option>
            <option value="warn">Warning</option>
            <option value="error">Error</option>
          </select>
          <button
            onClick={() => void fetchLogs()}
            className="px-4 py-2 bg-gray-100 dark:bg-gray-700 hover:bg-gray-200 dark:hover:bg-gray-600 rounded-lg text-sm font-medium transition-colors"
          >
            Refresh
          </button>
          <button
            onClick={() => void handleClear()}
            className="px-4 py-2 bg-red-100 dark:bg-red-900/30 hover:bg-red-200 dark:hover:bg-red-900/50 text-red-600 dark:text-red-400 rounded-lg text-sm font-medium transition-colors"
          >
            Clear
          </button>
        </div>
      </div>

      {/* Log Stats */}
      <div className="grid grid-cols-4 gap-4">
        {(['debug', 'info', 'warn', 'error'] as const).map((level) => (
          <div
            key={level}
            className="bg-white dark:bg-gray-800 rounded-xl p-3 shadow-sm border border-gray-200 dark:border-gray-700"
          >
            <span className="text-sm text-gray-500 dark:text-gray-400 capitalize">{level}</span>
            <p className="text-xl font-bold text-gray-900 dark:text-white">
              {logs.filter(l => l.level === level).length}
            </p>
          </div>
        ))}
      </div>

      {/* Logs List */}
      <div className="flex-1 bg-white dark:bg-gray-800 rounded-xl shadow-sm border border-gray-200 dark:border-gray-700 overflow-hidden">
        {isLoading ? (
          <div className="flex items-center justify-center h-64">
            <div className="w-8 h-8 border-4 border-primary-500 border-t-transparent rounded-full animate-spin" />
          </div>
        ) : filteredLogs.length > 0 ? (
          <div className="h-full overflow-auto">
            <table className="w-full">
              <thead className="bg-gray-50 dark:bg-gray-900 sticky top-0">
                <tr>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase">
                    Time
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase">
                    Level
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase">
                    Source
                  </th>
                  <th className="px-4 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-400 uppercase">
                    Message
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-200 dark:divide-gray-700">
                {filteredLogs.slice().reverse().map((log, index) => (
                  <tr key={index} className="hover:bg-gray-50 dark:hover:bg-gray-900/50">
                    <td className="px-4 py-3 text-sm text-gray-500 dark:text-gray-400 font-mono whitespace-nowrap">
                      {new Date(log.timestamp).toLocaleTimeString()}
                    </td>
                    <td className="px-4 py-3">
                      <span className={`px-2 py-1 rounded text-xs font-medium uppercase ${getLevelColor(log.level)}`}>
                        {log.level}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-300">
                      {log.source}
                    </td>
                    <td className="px-4 py-3 text-sm text-gray-900 dark:text-white">
                      {log.message}
                      {log.data && (
                        <pre className="mt-1 text-xs text-gray-500 dark:text-gray-400 overflow-x-auto">
                          {JSON.stringify(log.data, null, 2)}
                        </pre>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="flex flex-col items-center justify-center h-64 text-gray-500 dark:text-gray-400">
            <span className="text-4xl mb-4">📝</span>
            <p>No logs to display</p>
          </div>
        )}
      </div>
    </div>
  );
}
