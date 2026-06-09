// Generated from schema/contract.json. Do not edit manually.

export const contractVersion = 1 as const;

export type RequestKind = 'runtime.status' | 'runtime.start' | 'runtime.stop' | 'management.request';

export type EventKind = 'runtime.statusChanged';

export type RuntimeStatus = {
  state: string;
  endpoint?: string;
};

export type ManagementResponse = {
  status: number;
  body?: string;
};
