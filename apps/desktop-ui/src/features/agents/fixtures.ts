import type { AgentsResponse } from './types';

export const agentSupportStateFixture = {
  agents: [
    {
      id: 'claude',
      label: 'Claude Code',
      config_mode: 'file',
      platform_support: 'supported',
      rollback_available: true,
      capabilities: ['guide', 'diff', 'install', 'rollback'],
    },
    {
      id: 'gemini-cli',
      label: 'Gemini CLI',
      config_mode: 'environment',
      platform_support: 'supported',
      rollback_available: false,
      capabilities: ['guide', 'diff', 'install', 'rollback'],
    },
    {
      id: 'factory',
      label: 'Factory Droid',
      config_mode: 'file',
      platform_support: 'unsupported',
      rollback_available: false,
      message: 'This agent is not supported on this platform.',
      capabilities: ['guide', 'diff', 'install'],
    },
    {
      id: 'codex',
      label: 'Codex CLI',
      config_mode: 'file',
      platform_support: 'unknown',
      rollback_available: false,
      message:
        'Support for this agent has not been validated on this platform yet.',
      capabilities: ['guide', 'diff', 'install', 'rollback'],
    },
  ],
} satisfies AgentsResponse;
