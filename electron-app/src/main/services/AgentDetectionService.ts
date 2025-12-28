// ============================================
// Quotio - Agent Detection Service
// Detects and configures CLI AI agents
// ============================================

import { exec } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import { promisify } from 'util';
import { LoggerService } from './LoggerService';
import { ProxyManager } from './ProxyManager';
import { AGENT_CONFIG } from '../../shared/constants';
import type { CLIAgent, AgentConfiguration } from '../../shared/types';

const execAsync = promisify(exec);

type AgentType = keyof typeof AGENT_CONFIG;

export class AgentDetectionService {
  private static instance: AgentDetectionService;
  private logger = LoggerService.getInstance();
  private detectedAgents: Map<string, CLIAgent> = new Map();

  private constructor() {}

  static getInstance(): AgentDetectionService {
    if (!AgentDetectionService.instance) {
      AgentDetectionService.instance = new AgentDetectionService();
    }
    return AgentDetectionService.instance;
  }

  async detectAgents(): Promise<CLIAgent[]> {
    this.logger.info('Detecting installed CLI agents...');

    const agents: CLIAgent[] = [];

    for (const [agentType, config] of Object.entries(AGENT_CONFIG)) {
      try {
        const agent = await this.detectAgent(agentType as AgentType, config);
        if (agent) {
          agents.push(agent);
          this.detectedAgents.set(agent.id, agent);
        }
      } catch (error) {
        this.logger.debug('Agent not detected', { agentType, error });
      }
    }

    this.logger.info('Agent detection complete', { count: agents.length });
    return agents;
  }

  private async detectAgent(
    agentType: AgentType,
    config: typeof AGENT_CONFIG[AgentType]
  ): Promise<CLIAgent | null> {
    try {
      // Try to run the version command
      const { stdout } = await execAsync(config.detectCommand, {
        timeout: 5000,
        env: { ...process.env, PATH: this.getExtendedPath() },
      });

      const version = this.parseVersion(stdout);

      // Check if configured
      const configPath = this.getConfigFilePath(agentType, config);
      const isConfigured = this.checkIfConfigured(configPath);

      return {
        id: agentType,
        name: config.name,
        type: agentType as CLIAgent['type'],
        isInstalled: true,
        configPath,
        version,
        isConfigured,
      };
    } catch {
      // Agent not installed or not in PATH
      return {
        id: agentType,
        name: config.name,
        type: agentType as CLIAgent['type'],
        isInstalled: false,
        isConfigured: false,
      };
    }
  }

  private getExtendedPath(): string {
    const paths = [
      '/usr/local/bin',
      '/opt/homebrew/bin',
      path.join(os.homedir(), '.local', 'bin'),
      path.join(os.homedir(), 'bin'),
      path.join(os.homedir(), '.npm-global', 'bin'),
      path.join(os.homedir(), '.cargo', 'bin'),
    ];

    return [...paths, process.env.PATH].filter(Boolean).join(':');
  }

  private parseVersion(output: string): string {
    // Try to extract version number from output
    const versionMatch = output.match(/(\d+\.\d+\.\d+)/);
    return versionMatch ? versionMatch[1] : 'unknown';
  }

  private getConfigFilePath(agentType: string, config: typeof AGENT_CONFIG[AgentType]): string {
    // Different agents store configs in different locations
    const homeDir = os.homedir();

    switch (agentType) {
      case 'claude-code':
        return path.join(homeDir, '.claude.json');
      case 'codex-cli':
        return path.join(homeDir, '.codex', 'config.json');
      case 'gemini-cli':
        return path.join(homeDir, '.gemini', 'config.json');
      case 'amp-cli':
        return path.join(homeDir, '.amp', 'config.json');
      case 'opencode':
        return path.join(homeDir, '.opencode', 'config.json');
      case 'factory-droid':
        return path.join(homeDir, '.factory-droid', 'config.json');
      default:
        return path.join(homeDir, config.configFile);
    }
  }

  private checkIfConfigured(configPath: string): boolean {
    try {
      if (fs.existsSync(configPath)) {
        const content = fs.readFileSync(configPath, 'utf-8');
        const config = JSON.parse(content);
        // Check if proxy is configured
        return config.proxy_url || config.proxyUrl || config.base_url;
      }
    } catch {
      // Config file doesn't exist or is invalid
    }
    return false;
  }

  async configureAgent(config: AgentConfiguration | Record<string, unknown>): Promise<void> {
    const agentId = (config as AgentConfiguration).agentId || (config as Record<string, unknown>).agentId as string;

    if (!agentId) {
      throw new Error('Agent ID is required');
    }

    const agent = this.detectedAgents.get(agentId);

    if (!agent) {
      throw new Error(`Agent not found: ${agentId}`);
    }

    if (!agent.isInstalled) {
      throw new Error(`Agent not installed: ${agentId}`);
    }

    const proxyManager = ProxyManager.getInstance();
    const proxyPort = proxyManager.getPort();
    const managementKey = proxyManager.getManagementKey();

    const proxyUrl = `http://127.0.0.1:${proxyPort}`;

    try {
      await this.writeAgentConfig(agent, proxyUrl, managementKey);
      agent.isConfigured = true;
      this.logger.info('Agent configured successfully', { agentId, proxyUrl });
    } catch (error) {
      this.logger.error('Failed to configure agent', { agentId, error });
      throw error;
    }
  }

  private async writeAgentConfig(agent: CLIAgent, proxyUrl: string, apiKey: string): Promise<void> {
    if (!agent.configPath) {
      throw new Error('Config path not available for agent');
    }

    // Ensure config directory exists
    const configDir = path.dirname(agent.configPath);
    if (!fs.existsSync(configDir)) {
      fs.mkdirSync(configDir, { recursive: true });
    }

    // Read existing config or create new one
    let existingConfig: Record<string, unknown> = {};
    if (fs.existsSync(agent.configPath)) {
      try {
        existingConfig = JSON.parse(fs.readFileSync(agent.configPath, 'utf-8'));
      } catch {
        // Invalid JSON, start fresh
      }
    }

    // Agent-specific configuration
    let newConfig: Record<string, unknown>;

    switch (agent.type) {
      case 'claude-code':
        newConfig = {
          ...existingConfig,
          apiUrl: proxyUrl,
          apiKey: apiKey,
        };
        break;

      case 'codex-cli':
        newConfig = {
          ...existingConfig,
          openai_base_url: proxyUrl,
          api_key: apiKey,
        };
        break;

      case 'gemini-cli':
        newConfig = {
          ...existingConfig,
          api_url: proxyUrl,
          api_key: apiKey,
        };
        break;

      default:
        newConfig = {
          ...existingConfig,
          proxy_url: proxyUrl,
          api_key: apiKey,
        };
    }

    // Write config file
    fs.writeFileSync(agent.configPath, JSON.stringify(newConfig, null, 2));
    this.logger.debug('Agent config written', { path: agent.configPath });

    // Also update shell environment variable if needed
    await this.updateShellProfile(agent, proxyUrl, apiKey);
  }

  private async updateShellProfile(agent: CLIAgent, proxyUrl: string, apiKey: string): Promise<void> {
    const agentConfig = AGENT_CONFIG[agent.type as AgentType];
    if (!agentConfig?.envVar) return;

    const homeDir = os.homedir();
    const shell = process.env.SHELL || '/bin/bash';

    let profilePath: string;
    if (shell.includes('zsh')) {
      profilePath = path.join(homeDir, '.zshrc');
    } else if (shell.includes('fish')) {
      profilePath = path.join(homeDir, '.config', 'fish', 'config.fish');
    } else {
      profilePath = path.join(homeDir, '.bashrc');
    }

    try {
      let profileContent = '';
      if (fs.existsSync(profilePath)) {
        profileContent = fs.readFileSync(profilePath, 'utf-8');
      }

      // Check if already configured
      const envLine = `export ${agentConfig.envVar}="${apiKey}"`;
      const urlLine = `export ${agent.type.toUpperCase().replace(/-/g, '_')}_BASE_URL="${proxyUrl}"`;

      if (!profileContent.includes(agentConfig.envVar)) {
        const addition = `\n# Quotio proxy configuration\n${envLine}\n${urlLine}\n`;
        fs.appendFileSync(profilePath, addition);
        this.logger.debug('Shell profile updated', { path: profilePath });
      }
    } catch (error) {
      this.logger.warn('Failed to update shell profile', { error });
      // Non-fatal error, continue
    }
  }

  getDetectedAgents(): CLIAgent[] {
    return Array.from(this.detectedAgents.values());
  }

  getAgent(id: string): CLIAgent | undefined {
    return this.detectedAgents.get(id);
  }
}
