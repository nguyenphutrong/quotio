import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useCallback, useEffect, useMemo, useReducer, useRef } from 'react';
import { useAdminRuntime } from '@/lib/admin/runtime';
import type {
  AgentDiffResponse,
  AgentGuideResponse,
  AgentInstallResponse,
  AgentRollbackResponse,
  AgentsResponse,
} from './types';

type AgentAction = 'guide' | 'diff' | 'install' | 'rollback';
type AgentActionPayload =
  | AgentGuideResponse
  | AgentDiffResponse
  | AgentInstallResponse
  | AgentRollbackResponse;

export type AgentActionState = {
  action?: AgentAction;
  status: 'idle' | 'running' | 'success' | 'error';
  payload?: AgentActionPayload;
  error?: string;
  finishedAt?: number;
  installed?: boolean;
  rollbackAvailable?: boolean;
};

type AgentStateMap = Record<string, AgentActionState>;
type AgentStateAction =
  | { type: 'running'; agentId: string; action: AgentAction }
  | {
      type: 'success';
      agentId: string;
      action: AgentAction;
      payload: AgentActionPayload;
      finishedAt: number;
    }
  | {
      type: 'error';
      agentId: string;
      action: AgentAction;
      error: string;
      finishedAt: number;
    }
  | { type: 'reset_status'; agentId: string }
  | { type: 'reset'; agentId: string }
  | { type: 'reset_all' };

const idleState: AgentActionState = { status: 'idle' };

function agentStateReducer(
  state: AgentStateMap,
  action: AgentStateAction,
): AgentStateMap {
  if (action.type === 'reset_all') {
    return {};
  }

  if (action.type === 'reset') {
    return {
      ...state,
      [action.agentId]: idleState,
    };
  }

  if (action.type === 'reset_status') {
    const current = state[action.agentId];
    if (!current) {
      return state;
    }
    return {
      ...state,
      [action.agentId]: {
        ...current,
        status: 'idle',
        error: undefined,
      },
    };
  }

  if (action.type === 'running') {
    return {
      ...state,
      [action.agentId]: {
        ...state[action.agentId],
        action: action.action,
        status: 'running',
      },
    };
  }

  if (action.type === 'success') {
    return {
      ...state,
      [action.agentId]: {
        ...state[action.agentId],
        action: action.action,
        status: 'success',
        payload: action.payload,
        finishedAt: action.finishedAt,
        installed:
          'status' in action.payload
            ? action.payload.status.installed
            : state[action.agentId]?.installed,
        rollbackAvailable:
          'status' in action.payload
            ? action.payload.status.rollback_available
            : state[action.agentId]?.rollbackAvailable,
      },
    };
  }

  return {
    ...state,
    [action.agentId]: {
      ...state[action.agentId],
      action: action.action,
      status: 'error',
      error: action.error,
      finishedAt: action.finishedAt,
    },
  };
}

export function useAgentsQuery() {
  const { request } = useAdminRuntime();
  return useQuery({
    queryKey: ['agents'],
    queryFn: () => request<AgentsResponse>('/agents'),
  });
}

export function useAgentMutations() {
  const { request } = useAdminRuntime();
  const queryClient = useQueryClient();

  const invalidate = async () => {
    await queryClient.invalidateQueries({ queryKey: ['agents'] });
  };

  return {
    guideMutation: useMutation({
      mutationFn: (agent: string) =>
        request<AgentGuideResponse>(`/agents/${agent}/guide`),
    }),
    diffMutation: useMutation({
      mutationFn: (agent: string) =>
        request<AgentDiffResponse>(`/agents/${agent}/diff`, {
          method: 'POST',
          body: JSON.stringify({}),
        }),
    }),
    installMutation: useMutation({
      mutationFn: (agent: string) =>
        request<AgentInstallResponse>(`/agents/${agent}/install`, {
          method: 'POST',
          body: JSON.stringify({}),
        }),
      onSuccess: invalidate,
    }),
    rollbackMutation: useMutation({
      mutationFn: (agent: string) =>
        request<AgentRollbackResponse>(`/agents/${agent}/rollback`, {
          method: 'POST',
          body: JSON.stringify({}),
        }),
      onSuccess: invalidate,
    }),
  };
}

export function useAgentActions() {
  const mutations = useAgentMutations();
  const [state, dispatch] = useReducer(agentStateReducer, {});
  const timersRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(
    new Map(),
  );

  const clearTimer = useCallback((agentId: string) => {
    const timer = timersRef.current.get(agentId);
    if (!timer) {
      return;
    }
    clearTimeout(timer);
    timersRef.current.delete(agentId);
  }, []);

  const resetAgent = useCallback(
    (agentId: string) => {
      clearTimer(agentId);
      dispatch({ type: 'reset', agentId });
    },
    [clearTimer],
  );

  const setAutoReset = useCallback(
    (agentId: string) => {
      clearTimer(agentId);
      const timer = setTimeout(() => {
        dispatch({ type: 'reset_status', agentId });
        timersRef.current.delete(agentId);
      }, 4000);
      timersRef.current.set(agentId, timer);
    },
    [clearTimer],
  );

  const runAction = useCallback(
    async (
      agentId: string,
      action: AgentAction,
    ): Promise<AgentActionPayload> => {
      clearTimer(agentId);
      dispatch({ type: 'running', agentId, action });

      try {
        let payload: AgentActionPayload;
        if (action === 'guide') {
          payload = await mutations.guideMutation.mutateAsync(agentId);
        } else if (action === 'diff') {
          payload = await mutations.diffMutation.mutateAsync(agentId);
        } else if (action === 'install') {
          payload = await mutations.installMutation.mutateAsync(agentId);
        } else {
          payload = await mutations.rollbackMutation.mutateAsync(agentId);
        }

        dispatch({
          type: 'success',
          agentId,
          action,
          payload,
          finishedAt: Date.now(),
        });
        setAutoReset(agentId);

        if (action === 'install' || action === 'rollback') {
          try {
            const refreshedPayload =
              await mutations.diffMutation.mutateAsync(agentId);
            dispatch({
              type: 'success',
              agentId,
              action: 'diff',
              payload: refreshedPayload,
              finishedAt: Date.now(),
            });
          } catch {
            // Best effort only; keep original action success state.
          }
        }
        return payload;
      } catch (error) {
        const message =
          error instanceof Error ? error.message : 'Unknown action error';
        dispatch({
          type: 'error',
          agentId,
          action,
          error: message,
          finishedAt: Date.now(),
        });
        setAutoReset(agentId);
        throw error;
      }
    },
    [clearTimer, mutations, setAutoReset],
  );

  const getActionState = useCallback(
    (agentId: string): AgentActionState => state[agentId] ?? idleState,
    [state],
  );

  useEffect(
    () => () => {
      for (const timer of timersRef.current.values()) {
        clearTimeout(timer);
      }
      timersRef.current.clear();
      dispatch({ type: 'reset_all' });
    },
    [],
  );

  return useMemo(
    () => ({
      runAction,
      getActionState,
      resetAgent,
    }),
    [getActionState, resetAgent, runAction],
  );
}
