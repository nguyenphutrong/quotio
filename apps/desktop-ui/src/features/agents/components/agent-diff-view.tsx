import { Badge } from '@quotio/ui/components/badge';
import { useTranslation } from 'react-i18next';

const PREVIEW_MAX_LINES = 320;
const PREVIEW_MAX_CHARS = 20000;

type DiffFile = {
  target_path: string;
  existed: boolean;
  has_changes: boolean;
  before?: string;
  after?: string;
};

function clipPreview(content: string) {
  const normalized = content.replaceAll('\r\n', '\n');
  const lines = normalized.split('\n');
  const lineLimited = lines.slice(0, PREVIEW_MAX_LINES).join('\n');

  let text = lineLimited;
  let truncated = lines.length > PREVIEW_MAX_LINES;
  if (text.length > PREVIEW_MAX_CHARS) {
    text = text.slice(0, PREVIEW_MAX_CHARS);
    truncated = true;
  }

  return { text, truncated };
}

export function AgentDiffView({ files }: { files: DiffFile[] }) {
  const { t } = useTranslation();
  const changedCount = files.filter((file) => file.has_changes).length;

  return (
    <div className="space-y-3">
      <p className="text-xs text-muted-foreground">
        {changedCount}/{files.length}{' '}
        {t('agents.diff.fileChanged').toLowerCase()}
      </p>

      {files.map((file) => {
        const beforePreview = clipPreview(file.before ?? '');
        const afterPreview = clipPreview(file.after ?? '');
        const hasTruncatedPreview =
          beforePreview.truncated || afterPreview.truncated;

        return (
          <div
            key={file.target_path}
            className="space-y-2 rounded-md border border-border/70 p-3"
          >
            <div className="flex flex-wrap items-center gap-2">
              <p className="min-w-0 flex-1 break-all text-xs font-medium">
                {file.target_path}
              </p>
              <Badge variant={file.has_changes ? 'default' : 'secondary'}>
                {file.has_changes
                  ? t('agents.diff.fileChanged')
                  : t('agents.diff.fileUnchanged')}
              </Badge>
              {!file.existed ? (
                <Badge variant="outline">{t('agents.diff.fileNew')}</Badge>
              ) : null}
            </div>

            <div className="grid gap-2 lg:grid-cols-2">
              <div className="space-y-1">
                <p className="text-[11px] font-medium text-muted-foreground">
                  {t('agents.diff.before')}
                </p>
                <pre className="max-h-72 overflow-auto rounded-md border border-border/70 bg-muted/30 p-2 text-[11px]">
                  {beforePreview.text}
                </pre>
              </div>
              <div className="space-y-1">
                <p className="text-[11px] font-medium text-muted-foreground">
                  {t('agents.diff.after')}
                </p>
                <pre className="max-h-72 overflow-auto rounded-md border border-border/70 bg-muted/30 p-2 text-[11px]">
                  {afterPreview.text}
                </pre>
              </div>
            </div>

            {hasTruncatedPreview ? (
              <p className="text-[11px] text-muted-foreground">
                {t('agents.diff.truncated')}
              </p>
            ) : null}
          </div>
        );
      })}
    </div>
  );
}
