import { useEffect, useState } from 'react';
import { useTheme } from '@/components/theme-provider';

// Maps provider keys to filenames (most are the same)
const iconMap: Record<string, string> = {
  ag: 'antigravity',
  anthropic: 'claude',
  'azure-openai': 'azure',
  codex: 'openai',
  glm: 'zai',
  'opencode-go': 'opencode',
  'vertex (anthropic)': 'vertex',
  vertex_anthropic: 'vertex',
  zai: 'zai',
  'z-ai': 'zai',
  'z.ai': 'zai',
};

// Providers that need to invert color in dark mode (black to white)
const invertInDarkMode = [
  'openai',
  'ollama',
  'cortecs',
  'github-copilot',
  'fastrouter',
  'groq',
  'openrouter',
  'opencode',
  'opencode-go',
  'together',
  'vercel-ai-gateway',
  'xai',
  'z-ai',
  'custom',
];

export function ProviderIcon({
  provider,
  className = '',
}: {
  provider: string;
  className?: string;
}) {
  const [Icon, setIcon] = useState<string | null>(null);
  const [hasError, setHasError] = useState(false);
  const { theme } = useTheme();

  useEffect(() => {
    let isMounted = true;
    setHasError(false);

    const normalizedKey = provider.toLowerCase().trim();
    let filename = iconMap[normalizedKey] || normalizedKey;

    // Handle light/dark specific variant for kimi
    // Since theme can be 'system', we'll just check if it's explicitly 'dark'
    // or we can rely on standard window matchMedia if it's 'system'.
    const isDark =
      theme === 'dark' ||
      (theme === 'system' &&
        window.matchMedia('(prefers-color-scheme: dark)').matches);

    if (normalizedKey === 'kimi' && isDark) {
      filename = 'kimi-dark';
    }

    import(`../../assets/providers/${filename}.svg?url`)
      .then((mod) => {
        if (isMounted) setIcon(mod.default);
      })
      .catch(() => {
        // Fallback to models.dev if local one isn't found
        if (isMounted) setIcon(`https://models.dev/logos/${normalizedKey}.svg`);
      });

    return () => {
      isMounted = false;
    };
  }, [provider, theme]);

  if (hasError || !Icon) {
    return (
      <div
        className={`flex items-center justify-center bg-muted text-muted-foreground ${className}`}
      >
        {provider.charAt(0).toUpperCase()}
      </div>
    );
  }

  const normalizedKey = provider.toLowerCase().trim();
  const shouldInvert =
    invertInDarkMode.includes(normalizedKey) ||
    invertInDarkMode.includes(iconMap[normalizedKey] || '');

  return (
    <img
      src={Icon}
      alt={`${provider} icon`}
      className={`object-contain ${shouldInvert ? 'dark:invert' : ''} ${className}`}
      width={24}
      height={24}
      onError={() => {
        setHasError(true);
      }}
    />
  );
}
