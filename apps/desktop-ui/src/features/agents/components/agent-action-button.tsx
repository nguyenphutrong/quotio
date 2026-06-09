import { Button } from '@quotio/ui/components/button';
import { RiAlertLine, RiCheckLine, RiLoader4Line } from '@remixicon/react';
import type { AgentActionState } from '../api';

type AgentActionButtonProps = {
  label: string;
  state: AgentActionState;
  disabled?: boolean;
  onClick: () => void;
};

export function AgentActionButton({
  label,
  state,
  disabled,
  onClick,
}: AgentActionButtonProps) {
  const isRunning = state.status === 'running';
  const isSuccess = state.status === 'success';
  const isError = state.status === 'error';

  return (
    <Button
      type="button"
      size="sm"
      variant="outline"
      disabled={disabled || isRunning}
      onClick={onClick}
      aria-live="polite"
      aria-label={`${label} ${state.status}`}
    >
      {isRunning ? (
        <RiLoader4Line className="size-4 animate-spin" />
      ) : isSuccess ? (
        <RiCheckLine className="size-4 text-success" />
      ) : isError ? (
        <RiAlertLine className="size-4 text-danger" />
      ) : null}
      {label}
    </Button>
  );
}
