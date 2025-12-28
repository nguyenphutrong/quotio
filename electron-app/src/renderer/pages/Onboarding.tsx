import { useState } from 'react';
import type { AppSettings } from '@shared/types';

interface OnboardingProps {
  onComplete: () => void;
}

export default function Onboarding({ onComplete }: OnboardingProps): JSX.Element {
  const [step, setStep] = useState(0);
  const [selectedMode, setSelectedMode] = useState<'full' | 'quota-only'>('full');
  const [isLoading, setIsLoading] = useState(false);

  const handleComplete = async (): Promise<void> => {
    setIsLoading(true);
    try {
      await window.electron.settings.update({
        appMode: selectedMode,
        hasCompletedOnboarding: true,
      } as Partial<AppSettings> & { hasCompletedOnboarding: boolean });

      if (selectedMode === 'full') {
        await window.electron.proxy.start();
      }

      onComplete();
    } catch (error) {
      console.error('Failed to complete onboarding:', error);
    } finally {
      setIsLoading(false);
    }
  };

  const steps = [
    // Welcome
    <div key="welcome" className="text-center">
      <div className="text-6xl mb-6">🚀</div>
      <h1 className="text-3xl font-bold text-gray-900 dark:text-white mb-4">
        Welcome to Quotio
      </h1>
      <p className="text-gray-600 dark:text-gray-300 max-w-md mx-auto">
        Your command center for managing AI coding assistants. Monitor quotas, configure agents, and streamline your workflow.
      </p>
    </div>,

    // Mode Selection
    <div key="mode" className="text-center">
      <h2 className="text-2xl font-bold text-gray-900 dark:text-white mb-6">
        Choose Your Mode
      </h2>
      <div className="grid grid-cols-2 gap-4 max-w-2xl mx-auto">
        <button
          onClick={() => setSelectedMode('full')}
          className={`p-6 rounded-xl border-2 text-left transition-all ${
            selectedMode === 'full'
              ? 'border-primary-500 bg-primary-50 dark:bg-primary-900/20'
              : 'border-gray-200 dark:border-gray-700 hover:border-primary-300'
          }`}
        >
          <div className="text-3xl mb-3">🔄</div>
          <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-2">
            Full Mode
          </h3>
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Run a local proxy server that routes requests through your AI accounts. Best for managing multiple accounts with automatic failover.
          </p>
        </button>

        <button
          onClick={() => setSelectedMode('quota-only')}
          className={`p-6 rounded-xl border-2 text-left transition-all ${
            selectedMode === 'quota-only'
              ? 'border-primary-500 bg-primary-50 dark:bg-primary-900/20'
              : 'border-gray-200 dark:border-gray-700 hover:border-primary-300'
          }`}
        >
          <div className="text-3xl mb-3">📊</div>
          <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-2">
            Quota Only
          </h3>
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Monitor quotas from your existing CLI tools without running a proxy. Perfect for tracking usage across multiple accounts.
          </p>
        </button>
      </div>
    </div>,

    // Ready
    <div key="ready" className="text-center">
      <div className="text-6xl mb-6">✨</div>
      <h2 className="text-2xl font-bold text-gray-900 dark:text-white mb-4">
        You're All Set!
      </h2>
      <p className="text-gray-600 dark:text-gray-300 max-w-md mx-auto mb-6">
        Quotio is ready to use. You can change these settings anytime from the Settings page.
      </p>
      <div className="p-4 bg-gray-100 dark:bg-gray-800 rounded-xl max-w-sm mx-auto">
        <p className="text-sm text-gray-600 dark:text-gray-400">
          <strong>Selected Mode:</strong> {selectedMode === 'full' ? 'Full Mode' : 'Quota Only'}
        </p>
      </div>
    </div>,
  ];

  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-900 flex flex-col">
      {/* Title bar drag region */}
      <div className="h-8 drag-region" />

      {/* Content */}
      <div className="flex-1 flex flex-col items-center justify-center p-8">
        <div className="w-full max-w-2xl">
          {/* Progress */}
          <div className="flex items-center justify-center gap-2 mb-12">
            {steps.map((_, i) => (
              <div
                key={i}
                className={`h-2 rounded-full transition-all ${
                  i === step
                    ? 'w-8 bg-primary-500'
                    : i < step
                    ? 'w-2 bg-primary-300'
                    : 'w-2 bg-gray-300 dark:bg-gray-600'
                }`}
              />
            ))}
          </div>

          {/* Step Content */}
          <div className="mb-12">
            {steps[step]}
          </div>

          {/* Navigation */}
          <div className="flex items-center justify-center gap-4">
            {step > 0 && (
              <button
                onClick={() => setStep(s => s - 1)}
                className="px-6 py-3 bg-gray-100 dark:bg-gray-700 hover:bg-gray-200 dark:hover:bg-gray-600 rounded-xl font-medium text-gray-700 dark:text-gray-300 transition-colors"
              >
                Back
              </button>
            )}

            {step < steps.length - 1 ? (
              <button
                onClick={() => setStep(s => s + 1)}
                className="px-8 py-3 bg-primary-500 hover:bg-primary-600 text-white rounded-xl font-medium transition-colors"
              >
                Continue
              </button>
            ) : (
              <button
                onClick={() => void handleComplete()}
                disabled={isLoading}
                className="px-8 py-3 bg-primary-500 hover:bg-primary-600 disabled:opacity-50 text-white rounded-xl font-medium transition-colors flex items-center gap-2"
              >
                {isLoading && (
                  <div className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin" />
                )}
                Get Started
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
