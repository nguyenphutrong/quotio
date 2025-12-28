import { Routes, Route, Navigate } from 'react-router-dom';
import { useEffect, useState } from 'react';
import Layout from './components/Layout';
import Dashboard from './pages/Dashboard';
import Quotas from './pages/Quotas';
import Providers from './pages/Providers';
import Agents from './pages/Agents';
import Settings from './pages/Settings';
import Logs from './pages/Logs';
import Onboarding from './pages/Onboarding';
import { AppProvider } from './store/AppContext';
import type { AppSettings } from '@shared/types';

function App(): JSX.Element {
  const [isLoading, setIsLoading] = useState(true);
  const [hasOnboarded, setHasOnboarded] = useState(true);

  useEffect(() => {
    const initApp = async (): Promise<void> => {
      try {
        const settings = await window.electron.settings.get() as AppSettings & { hasCompletedOnboarding?: boolean };
        setHasOnboarded(settings.hasCompletedOnboarding ?? true);
      } catch (error) {
        console.error('Failed to load settings:', error);
      } finally {
        setIsLoading(false);
      }
    };

    void initApp();
  }, []);

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-screen bg-gray-50 dark:bg-gray-900">
        <div className="flex flex-col items-center gap-4">
          <div className="w-12 h-12 border-4 border-primary-500 border-t-transparent rounded-full animate-spin" />
          <span className="text-gray-600 dark:text-gray-300">Loading Quotio...</span>
        </div>
      </div>
    );
  }

  if (!hasOnboarded) {
    return (
      <AppProvider>
        <Onboarding onComplete={() => setHasOnboarded(true)} />
      </AppProvider>
    );
  }

  return (
    <AppProvider>
      <Routes>
        <Route path="/" element={<Layout />}>
          <Route index element={<Navigate to="/dashboard" replace />} />
          <Route path="dashboard" element={<Dashboard />} />
          <Route path="quotas" element={<Quotas />} />
          <Route path="providers" element={<Providers />} />
          <Route path="agents" element={<Agents />} />
          <Route path="settings" element={<Settings />} />
          <Route path="logs" element={<Logs />} />
        </Route>
      </Routes>
    </AppProvider>
  );
}

export default App;
