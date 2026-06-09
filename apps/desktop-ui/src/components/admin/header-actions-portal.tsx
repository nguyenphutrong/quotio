import {
  createContext,
  type ReactNode,
  useContext,
  useEffect,
  useState,
} from 'react';
import { createPortal } from 'react-dom';

type HeaderActionsContextValue = {
  node: HTMLElement | null;
  setNode: (el: HTMLElement | null) => void;
};

const HeaderActionsContext = createContext<HeaderActionsContextValue | null>(
  null,
);

export function HeaderActionsProvider({ children }: { children: ReactNode }) {
  const [node, setNode] = useState<HTMLElement | null>(null);
  return (
    <HeaderActionsContext.Provider value={{ node, setNode }}>
      {children}
    </HeaderActionsContext.Provider>
  );
}

/**
 * Target slot - mount this inside a page header's actions prop to receive
 * portaled content from descendant components.
 */
export function HeaderActionsSlot({ className }: { className?: string }) {
  const ctx = useContext(HeaderActionsContext);
  return (
    <div
      ref={(el) => {
        ctx?.setNode(el);
      }}
      className={className}
    />
  );
}

/**
 * Source portal - render this inside a descendant component to send its
 * children into the nearest HeaderActionsSlot.
 */
export function HeaderActionsPortal({ children }: { children: ReactNode }) {
  const ctx = useContext(HeaderActionsContext);
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  if (!mounted || !ctx?.node) return null;
  return createPortal(children, ctx.node);
}
