// Generated from schema/contract.json. Do not edit manually.

export const contractVersion = 1 as const;

export type RequestKind = 'runtime.status' | 'runtime.start' | 'runtime.stop' | 'runtime.restart' | 'management.request' | 'native.confirm' | 'native.openExternal' | 'native.openTextFile';

export type EventKind = 'runtime.statusChanged';

export type RuntimeStatus = {
  state: string;
  endpoint?: string;
};

export type ManagementResponse = {
  status: number;
  body?: string;
};

export type AgentDescriptor = {
  id: string;
  displayName: string;
  configType: string;
  binaryNames: string[];
  macosConfigPaths: string[];
  windowsConfigPaths: string[];
  macosSupport: string;
  windowsSupport: string;
  backupPolicy: string;
  docsUrl?: string;
};

export type AgentDetectionStatus = {
  agentId: string;
  platformSupport: string;
  installed: boolean;
  configured: boolean;
  rollbackAvailable: boolean;
  binaryPath?: string;
  version?: string;
  message?: string;
};
