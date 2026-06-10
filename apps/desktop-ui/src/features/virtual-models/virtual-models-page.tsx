import {
  closestCenter,
  DndContext,
  type DragEndEvent,
  KeyboardSensor,
  PointerSensor,
  useSensor,
  useSensors,
} from '@dnd-kit/core';
import {
  arrayMove,
  SortableContext,
  sortableKeyboardCoordinates,
  useSortable,
  verticalListSortingStrategy,
} from '@dnd-kit/sortable';
import { Button } from '@quotio/ui/components/button';
import { Checkbox } from '@quotio/ui/components/checkbox';
import { Input } from '@quotio/ui/components/input';
import { Switch } from '@quotio/ui/components/switch';
import { Textarea } from '@quotio/ui/components/textarea';
import {
  RiAddLine,
  RiDeleteBinLine,
  RiDownloadLine,
  RiEditLine,
  RiFileUploadLine,
  RiRefreshLine,
  RiSearchLine,
} from '@remixicon/react';
import { useEffect, useMemo, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { AdminPageHeader } from '@/components/admin/admin-page-header';
import { CopyButton } from '@/components/admin/copy-button';
import { EmptyState } from '@/components/admin/empty-state';
import { ErrorState } from '@/components/admin/error-state';
import { LoadingState } from '@/components/admin/loading-state';
import { Panel } from '@/components/admin/panel';
import { ProviderIcon } from '@/components/admin/provider-icon';
import { useToast } from '@/components/admin/toast-provider';
import { useAdminRuntime } from '@/lib/admin/runtime';
import {
  useAvailableTargetsQuery,
  useVirtualModelMutations,
  useVirtualModelsStateQuery,
} from './api';
import type {
  AvailableTarget,
  RawVirtualModelExportPayload,
  VirtualModelEntry,
  VirtualModelRow,
} from './types';

function sortEntries(entries?: VirtualModelEntry[]) {
  return [...(entries ?? [])].sort(
    (left, right) => left.priority - right.priority,
  );
}

function isValidVirtualModelEntry(entry: VirtualModelEntry | null | undefined) {
  return typeof entry?.target === 'string' && entry.target.trim().length > 0;
}

function parseTarget(target?: string) {
  if (typeof target !== 'string' || target.trim().length === 0) {
    return {
      isValid: false,
      kind: 'unknown' as const,
      provider: 'unknown',
      modelId: '',
    };
  }

  const trimmedTarget = target.trim();
  if (!trimmedTarget.includes('/')) {
    return {
      isValid: true,
      kind: 'virtual' as const,
      provider: 'quotio',
      modelId: trimmedTarget,
    };
  }

  const [provider, ...rest] = trimmedTarget.split('/');
  const modelId = rest.join('/');

  return {
    isValid: provider.trim().length > 0 && modelId.trim().length > 0,
    kind: 'direct' as const,
    provider: provider.trim() || 'unknown',
    modelId,
  };
}

function getAvailableTargetTitle(target: AvailableTarget) {
  if (target.kind === 'virtual') {
    return `quotio/${target.modelId}`;
  }

  if (target.modelId.startsWith(`${target.provider}/`)) {
    return target.modelId.slice(target.provider.length + 1);
  }

  return target.modelId;
}

function getAvailableTargetDialogTitle(target: AvailableTarget) {
  if (target.kind === 'virtual') {
    return target.modelId;
  }

  const parsed = parseTarget(target.target);
  if (!parsed.isValid) {
    return getAvailableTargetTitle(target);
  }

  const normalizedModelId = parsed.modelId.startsWith(`${parsed.provider}/`)
    ? parsed.modelId.slice(parsed.provider.length + 1)
    : parsed.modelId;

  return `${parsed.provider}/${normalizedModelId}`;
}

function getEntryTargetTitle(target?: string) {
  const parsed = parseTarget(target);
  if (!parsed.isValid) {
    return null;
  }

  if (parsed.kind === 'virtual') {
    return `quotio/${parsed.modelId}`;
  }

  const normalizedModelId = parsed.modelId.startsWith(`${parsed.provider}/`)
    ? parsed.modelId.slice(parsed.provider.length + 1)
    : parsed.modelId;

  return `${parsed.provider}/${normalizedModelId}`;
}

function getAvailableTargetSearchText(target: AvailableTarget) {
  return [
    getAvailableTargetTitle(target),
    getAvailableTargetDialogTitle(target),
    target.modelId,
    target.provider,
    target.target,
    target.kind,
    target.kind === 'virtual' ? `quotio/${target.modelId}` : '',
  ]
    .join(' ')
    .toLowerCase();
}

function toTransformStyle(
  transform: {
    x: number;
    y: number;
    scaleX: number;
    scaleY: number;
  } | null,
) {
  if (!transform) {
    return undefined;
  }

  return `translate3d(0px, ${transform.y}px, 0) scaleX(${transform.scaleX}) scaleY(${transform.scaleY})`;
}

type ModelDialogState =
  | { mode: 'create' }
  | { mode: 'rename'; model: VirtualModelRow }
  | null;

type EntryDialogState = {
  model: VirtualModelRow;
} | null;

export function VirtualModelsPage() {
  const { t } = useTranslation();
  const toast = useToast();
  const { bootstrap, confirm } = useAdminRuntime();
  const stateQuery = useVirtualModelsStateQuery();
  const mutations = useVirtualModelMutations();
  const [modelDialog, setModelDialog] = useState<ModelDialogState>(null);
  const [entryDialog, setEntryDialog] = useState<EntryDialogState>(null);
  const [importOpen, setImportOpen] = useState(false);
  const [exportOpen, setExportOpen] = useState(false);

  const enabled = stateQuery.data?.enabled ?? false;
  const models = stateQuery.data?.models ?? [];
  const canManageVirtualModels =
    bootstrap.capabilities.supportsVirtualModelManagement;
  const targetsQuery = useAvailableTargetsQuery(entryDialog?.model.id ?? null);

  const exportJson = useMemo(() => {
    const payload = mutations.exportMutation.data;
    return payload ? JSON.stringify(payload, null, 2) : '';
  }, [mutations.exportMutation.data]);

  if (stateQuery.isLoading) {
    return <LoadingState label={t('virtualModels.loading')} />;
  }

  if (stateQuery.error) {
    return (
      <ErrorState
        title={t('virtualModels.failedToLoad')}
        description={
          stateQuery.error instanceof Error
            ? stateQuery.error.message
            : t('common.unknownError')
        }
        actionLabel={t('common.retry')}
        onAction={() => void stateQuery.refetch()}
      />
    );
  }

  return (
    <div className="flex h-full flex-col space-y-3">
      <AdminPageHeader
        title={t('virtualModels.title')}
        description={t('virtualModels.description')}
        actions={
          <div className="flex flex-wrap items-center gap-2">
            <Button
              variant="outline"
              size="sm"
              onClick={() => void stateQuery.refetch()}
              disabled={stateQuery.isRefetching}
            >
              <RiRefreshLine />
              {t('common.refresh')}
            </Button>
            <Button
              variant="outline"
              size="sm"
              onClick={() => setImportOpen(true)}
              disabled={!canManageVirtualModels}
            >
              <RiFileUploadLine />
              {t('virtualModels.actions.import')}
            </Button>
            <Button
              variant="outline"
              size="sm"
              onClick={async () => {
                try {
                  await mutations.exportMutation.mutateAsync();
                  setExportOpen(true);
                } catch (error) {
                  toast.error(
                    error instanceof Error
                      ? error.message
                      : t('virtualModels.messages.exportFailed'),
                  );
                }
              }}
              disabled={
                mutations.exportMutation.isPending || !canManageVirtualModels
              }
            >
              <RiDownloadLine />
              {t('virtualModels.actions.export')}
            </Button>
            <Button
              size="sm"
              onClick={() => setModelDialog({ mode: 'create' })}
              disabled={!enabled || !canManageVirtualModels}
            >
              <RiAddLine />
              {t('virtualModels.actions.create')}
            </Button>
          </div>
        }
      />

      <Panel className="space-y-2 p-3.5">
        <div className="flex items-start justify-between gap-2.5">
          <div className="space-y-1">
            <h2 className="text-sm font-semibold text-foreground">
              {t('virtualModels.global.title')}
            </h2>
            <p className="text-xs text-muted-foreground">
              {t('virtualModels.global.description')}
            </p>
          </div>
          <Switch
            checked={enabled}
            onCheckedChange={async (checked) => {
              try {
                await mutations.setEnabledMutation.mutateAsync(
                  Boolean(checked),
                );
                toast.success(
                  checked
                    ? t('virtualModels.messages.enabled')
                    : t('virtualModels.messages.disabled'),
                );
              } catch (error) {
                toast.error(
                  error instanceof Error
                    ? error.message
                    : t('virtualModels.messages.toggleFailed'),
                );
              }
            }}
            disabled={
              mutations.setEnabledMutation.isPending || !canManageVirtualModels
            }
          />
        </div>
      </Panel>

      <div className="space-y-2.5">
        <div>
          <h2 className="text-sm font-semibold text-foreground">
            {t('virtualModels.list.title')}
          </h2>
          <p className="text-xs text-muted-foreground">
            {t('virtualModels.list.description')}
          </p>
        </div>

        {models.length === 0 ? (
          <EmptyState
            title={
              enabled
                ? t('virtualModels.empty.title')
                : t('virtualModels.empty.disabledTitle')
            }
            description={
              enabled
                ? t('virtualModels.empty.description')
                : t('virtualModels.empty.disabledDescription')
            }
          />
        ) : (
          <div className="space-y-3">
            {models.map((model) => (
              <VirtualModelPanel
                key={model.id}
                model={model}
                globalEnabled={enabled}
                canManage={canManageVirtualModels}
                onRename={() => setModelDialog({ mode: 'rename', model })}
                onAddEntry={() => setEntryDialog({ model })}
                onToggle={async () => {
                  try {
                    await mutations.updateModelMutation.mutateAsync({
                      modelId: model.id,
                      payload: { disabled: !model.disabled },
                    });
                    toast.success(
                      model.disabled
                        ? t('virtualModels.messages.modelEnabled', {
                            name: model.name,
                          })
                        : t('virtualModels.messages.modelDisabled', {
                            name: model.name,
                          }),
                    );
                  } catch (error) {
                    toast.error(
                      error instanceof Error
                        ? error.message
                        : t('virtualModels.messages.modelUpdateFailed'),
                    );
                  }
                }}
                onDelete={async () => {
                  const accepted = await confirm({
                    title: t('virtualModels.dialogs.deleteModelTitle'),
                    message: t('virtualModels.dialogs.deleteModelDescription', {
                      name: model.name,
                    }),
                    confirmLabel: t('virtualModels.actions.delete'),
                    cancelLabel: t('common.cancel'),
                    destructive: true,
                  });

                  if (!accepted) {
                    return;
                  }

                  try {
                    await mutations.deleteModelMutation.mutateAsync(model.id);
                    toast.success(
                      t('virtualModels.messages.modelDeleted', {
                        name: model.name,
                      }),
                    );
                  } catch (error) {
                    toast.error(
                      error instanceof Error
                        ? error.message
                        : t('virtualModels.messages.modelDeleteFailed'),
                    );
                  }
                }}
                onReorderEntries={async (entryIds) => {
                  const sorted = sortEntries(model.entries);
                  if (sorted.some((entry) => !entry.hasStableId)) {
                    toast.error(t('virtualModels.messages.reorderUnavailable'));
                    throw new Error(
                      t('virtualModels.messages.reorderUnavailable'),
                    );
                  }

                  try {
                    await mutations.reorderEntriesMutation.mutateAsync({
                      modelId: model.id,
                      entryIds,
                    });
                    toast.success(
                      t('virtualModels.messages.reorderSaved', {
                        name: model.name,
                      }),
                    );
                  } catch (error) {
                    toast.error(
                      error instanceof Error
                        ? error.message
                        : t('virtualModels.messages.reorderFailed'),
                    );
                    throw error;
                  }
                }}
                onDeleteEntry={async (entryId) => {
                  const entry = model.entries.find(
                    (item) => item.id === entryId,
                  );
                  const entryLabel =
                    getEntryTargetTitle(entry?.target) ??
                    entry?.target ??
                    entryId;
                  const accepted = await confirm({
                    title: t('virtualModels.dialogs.deleteEntryTitle'),
                    message: t('virtualModels.dialogs.deleteEntryDescription', {
                      target: entryLabel,
                      name: model.name,
                    }),
                    confirmLabel: t('virtualModels.actions.delete'),
                    cancelLabel: t('common.cancel'),
                    destructive: true,
                  });

                  if (!accepted) {
                    return;
                  }

                  try {
                    await mutations.deleteEntryMutation.mutateAsync({
                      modelId: model.id,
                      entryId,
                    });
                    toast.success(
                      t('virtualModels.messages.entryDeleted', {
                        name: model.name,
                      }),
                    );
                  } catch (error) {
                    toast.error(
                      error instanceof Error
                        ? error.message
                        : t('virtualModels.messages.entryDeleteFailed'),
                    );
                  }
                }}
              />
            ))}
          </div>
        )}
      </div>

      <VirtualModelDialog
        open={modelDialog !== null}
        title={
          modelDialog?.mode === 'rename'
            ? t('virtualModels.dialogs.renameTitle')
            : t('virtualModels.dialogs.createTitle')
        }
        description={t('virtualModels.dialogs.modelDescription')}
        initialValue={
          modelDialog?.mode === 'rename' ? modelDialog.model.name : ''
        }
        confirmLabel={
          modelDialog?.mode === 'rename'
            ? t('common.save')
            : t('virtualModels.actions.create')
        }
        busy={
          mutations.createModelMutation.isPending ||
          mutations.updateModelMutation.isPending
        }
        disabled={!canManageVirtualModels}
        onOpenChange={(open) => {
          if (!open) {
            setModelDialog(null);
          }
        }}
        onSubmit={async (value) => {
          try {
            if (modelDialog?.mode === 'rename') {
              await mutations.updateModelMutation.mutateAsync({
                modelId: modelDialog.model.id,
                payload: { name: value },
              });
              toast.success(
                t('virtualModels.messages.modelRenamed', {
                  name: value,
                }),
              );
            } else {
              await mutations.createModelMutation.mutateAsync(value);
              toast.success(
                t('virtualModels.messages.modelCreated', {
                  name: value,
                }),
              );
            }
            setModelDialog(null);
          } catch (error) {
            toast.error(
              error instanceof Error
                ? error.message
                : t('virtualModels.messages.modelSaveFailed'),
            );
          }
        }}
      />

      <AddEntryDialog
        open={entryDialog !== null}
        model={entryDialog?.model ?? null}
        targets={targetsQuery.data?.models ?? []}
        busy={mutations.addEntryMutation.isPending || targetsQuery.isLoading}
        disabled={!canManageVirtualModels}
        onOpenChange={(open) => {
          if (!open) {
            setEntryDialog(null);
          }
        }}
        onSubmit={async (targets) => {
          if (!entryDialog) {
            return;
          }

          try {
            await mutations.addEntryMutation.mutateAsync({
              modelId: entryDialog.model.id,
              targets,
            });
            toast.success(
              t('virtualModels.messages.entryAdded', {
                name: entryDialog.model.name,
                count: targets.length,
              }),
            );
            setEntryDialog(null);
          } catch (error) {
            toast.error(
              error instanceof Error
                ? error.message
                : t('virtualModels.messages.entryAddFailed'),
            );
          }
        }}
      />

      <ImportDialog
        open={importOpen}
        busy={mutations.importMutation.isPending}
        disabled={!canManageVirtualModels}
        onOpenChange={setImportOpen}
        onSubmit={async (payload) => {
          try {
            await mutations.importMutation.mutateAsync(payload);
            toast.success(t('virtualModels.messages.importComplete'));
            setImportOpen(false);
          } catch (error) {
            toast.error(
              error instanceof Error
                ? error.message
                : t('virtualModels.messages.importFailed'),
            );
          }
        }}
      />

      <ExportDialog
        open={exportOpen}
        value={exportJson}
        onOpenChange={setExportOpen}
      />
    </div>
  );
}

function VirtualModelPanel({
  model,
  globalEnabled,
  canManage,
  onRename,
  onAddEntry,
  onToggle,
  onDelete,
  onReorderEntries,
  onDeleteEntry,
}: {
  model: VirtualModelRow;
  globalEnabled: boolean;
  canManage: boolean;
  onRename: () => void;
  onAddEntry: () => void;
  onToggle: () => void;
  onDelete: () => void;
  onReorderEntries: (entryIds: string[]) => Promise<void>;
  onDeleteEntry: (entryId: string) => void;
}) {
  const { t } = useTranslation();
  const [expanded, setExpanded] = useState(true);
  const [orderedEntries, setOrderedEntries] = useState(() =>
    sortEntries(model.entries),
  );
  const sortedEntries = orderedEntries;
  const canReorder =
    globalEnabled &&
    canManage &&
    sortedEntries.every((entry) => entry.hasStableId);
  const sensors = useSensors(
    useSensor(PointerSensor, {
      activationConstraint: {
        distance: 6,
      },
    }),
    useSensor(KeyboardSensor, {
      coordinateGetter: sortableKeyboardCoordinates,
    }),
  );

  useEffect(() => {
    setOrderedEntries(sortEntries(model.entries));
  }, [model.entries]);

  function handleDragEnd(event: DragEndEvent) {
    const { active, over } = event;

    if (!canReorder || !over || active.id === over.id) {
      return;
    }

    const previous = [...orderedEntries];
    const oldIndex = orderedEntries.findIndex(
      (entry) => entry.id === active.id,
    );
    const newIndex = orderedEntries.findIndex((entry) => entry.id === over.id);

    if (oldIndex < 0 || newIndex < 0) {
      return;
    }

    const next = arrayMove(orderedEntries, oldIndex, newIndex);
    setOrderedEntries(next);

    void onReorderEntries(next.map((entry) => entry.id)).catch(() => {
      setOrderedEntries(previous);
    });
  }

  return (
    <Panel className="space-y-2.5 p-3.5">
      <div className="flex flex-wrap items-start justify-between gap-2.5">
        <div className="space-y-1">
          <div className="flex items-center gap-2">
            <button
              type="button"
              className="text-left"
              onClick={() => setExpanded((current) => !current)}
            >
              <span className="text-sm font-semibold text-foreground">
                {model.name}
              </span>
            </button>
            <CopyButton
              variant="ghost"
              size="icon-xs"
              value={model.name}
              successMessage={t('models.messages.copied', {
                model: model.name,
              })}
              errorMessage={t('models.messages.copyFailed')}
              title={t('virtualModels.actions.copyModelName')}
              onClick={(event) => {
                event.stopPropagation();
              }}
            />
            {model.disabled ? (
              <span className="rounded-full bg-muted px-1.5 py-0.5 text-[11px] text-muted-foreground">
                {t('virtualModels.list.disabled')}
              </span>
            ) : null}
          </div>
          <p className="text-xs text-muted-foreground">
            {t('virtualModels.list.entryCount', {
              count: sortedEntries.length,
            })}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-1.5">
          <Button
            variant="outline"
            size="xs"
            onClick={onRename}
            disabled={!canManage}
          >
            <RiEditLine />
            {t('virtualModels.actions.rename')}
          </Button>
          <Button
            variant="outline"
            size="xs"
            onClick={onDelete}
            disabled={!canManage}
          >
            <RiDeleteBinLine />
            {t('virtualModels.actions.delete')}
          </Button>
          <Button
            variant="outline"
            size="xs"
            onClick={onToggle}
            disabled={!globalEnabled || !canManage}
          >
            {model.disabled
              ? t('virtualModels.actions.enableModel')
              : t('virtualModels.actions.disableModel')}
          </Button>
          <Button
            size="xs"
            onClick={onAddEntry}
            disabled={!globalEnabled || !canManage}
          >
            <RiAddLine />
            {t('virtualModels.actions.addEntry')}
          </Button>
        </div>
      </div>

      {expanded ? (
        sortedEntries.length === 0 ? (
          <EmptyState
            title={t('virtualModels.entries.emptyTitle')}
            description={t('virtualModels.entries.emptyDescription')}
          />
        ) : (
          <DndContext
            sensors={sensors}
            collisionDetection={closestCenter}
            onDragEnd={handleDragEnd}
          >
            <SortableContext
              items={sortedEntries.map((entry) => entry.id)}
              strategy={verticalListSortingStrategy}
            >
              <div className="space-y-2">
                {sortedEntries.map((entry) => (
                  <VirtualModelEntryRow
                    key={entry.id}
                    entry={entry}
                    dragEnabled={canReorder}
                    canManage={canManage}
                    onDelete={() => onDeleteEntry(entry.id)}
                  />
                ))}
              </div>
            </SortableContext>
          </DndContext>
        )
      ) : null}
    </Panel>
  );
}

function VirtualModelEntryRow({
  entry,
  dragEnabled,
  canManage,
  onDelete,
}: {
  entry: VirtualModelEntry;
  dragEnabled: boolean;
  canManage: boolean;
  onDelete: () => void;
}) {
  const { t } = useTranslation();
  const target = parseTarget(entry.target);
  const displayTarget = getEntryTargetTitle(entry.target);
  const canMutateEntry = entry.hasStableId && isValidVirtualModelEntry(entry);
  const {
    attributes,
    listeners,
    setNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({
    id: entry.id,
    disabled: !dragEnabled || !canMutateEntry,
  });

  return (
    <div
      ref={setNodeRef}
      style={{
        transform: toTransformStyle(transform),
        transition,
      }}
      className={`flex flex-wrap items-center gap-2 rounded-xl border px-2.5 py-2 ${
        isDragging
          ? 'border-primary/50 bg-background shadow-lg ring-1 ring-primary/20'
          : 'border-border/60 bg-muted/20'
      }`}
      title={
        dragEnabled && canMutateEntry
          ? t('virtualModels.actions.dragToReorder')
          : undefined
      }
      {...attributes}
      {...listeners}
    >
      <div className="flex size-6 items-center justify-center rounded-full bg-primary/10 text-[11px] font-semibold text-primary">
        {entry.priority}
      </div>
      {target.kind === 'direct' ? (
        <ProviderIcon provider={target.provider} className="size-[18px]" />
      ) : (
        <div className="flex size-[18px] items-center justify-center rounded-full bg-primary/10 text-[10px] font-semibold text-primary">
          Q
        </div>
      )}
      <div className="min-w-0 flex-1">
        <div className="truncate font-mono text-xs font-medium leading-tight text-foreground">
          {displayTarget ?? t('virtualModels.entries.invalidTarget')}
        </div>
      </div>
      <div className="flex items-center gap-2">
        <Button
          variant="outline"
          size="icon-sm"
          onPointerDown={(event) => {
            event.stopPropagation();
          }}
          onClick={(event) => {
            event.stopPropagation();
            onDelete();
          }}
          disabled={!canMutateEntry || !canManage}
          title={t('virtualModels.actions.deleteEntry')}
        >
          <RiDeleteBinLine />
        </Button>
      </div>
    </div>
  );
}

function VirtualModelDialog({
  open,
  title,
  description,
  initialValue,
  confirmLabel,
  busy,
  disabled,
  onOpenChange,
  onSubmit,
}: {
  open: boolean;
  title: string;
  description: string;
  initialValue: string;
  confirmLabel: string;
  busy: boolean;
  disabled: boolean;
  onOpenChange: (open: boolean) => void;
  onSubmit: (value: string) => Promise<void>;
}) {
  const { t } = useTranslation();
  const [value, setValue] = useState(initialValue);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setValue(initialValue);
      setError(null);
    }
  }, [initialValue, open]);

  const normalized = value.trim();

  if (!open) {
    return null;
  }

  return (
    <Panel className="space-y-4">
      <div>
        <h2 className="text-sm font-semibold text-foreground">{title}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{description}</p>
      </div>
      <div className="space-y-2">
        <label
          className="text-sm font-medium text-foreground"
          htmlFor="model-name"
        >
          {t('virtualModels.fields.name')}
        </label>
        <Input
          id="model-name"
          value={value}
          onChange={(event) => {
            setValue(event.target.value);
            if (error) {
              setError(null);
            }
          }}
          placeholder={t('virtualModels.fields.namePlaceholder')}
        />
        {error ? (
          <p className="text-xs text-destructive">{error}</p>
        ) : (
          <p className="text-xs text-muted-foreground">
            {t('virtualModels.fields.nameHint')}
          </p>
        )}
      </div>
      <div className="flex justify-end gap-2">
        <Button variant="outline" onClick={() => onOpenChange(false)}>
          {t('common.cancel')}
        </Button>
        <Button
          onClick={async () => {
            if (!normalized) {
              setError(t('virtualModels.validation.nameRequired'));
              return;
            }
            await onSubmit(normalized);
          }}
          disabled={busy || disabled}
        >
          {confirmLabel}
        </Button>
      </div>
    </Panel>
  );
}

function AddEntryDialog({
  open,
  model,
  targets,
  busy,
  disabled,
  onOpenChange,
  onSubmit,
}: {
  open: boolean;
  model: VirtualModelRow | null;
  targets: AvailableTarget[];
  busy: boolean;
  disabled: boolean;
  onOpenChange: (open: boolean) => void;
  onSubmit: (targets: string[]) => Promise<void>;
}) {
  const { t } = useTranslation();
  const [search, setSearch] = useState('');
  const [selectedTargets, setSelectedTargets] = useState<Set<string>>(
    new Set(),
  );
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setSearch('');
      setSelectedTargets(new Set());
      setError(null);
    }
  }, [open]);

  const availableTargets = useMemo(() => {
    if (!model) {
      return [];
    }

    const selectedTargets = new Set(model.entries.map((entry) => entry.target));

    return targets.filter((target) => !selectedTargets.has(target.target));
  }, [model, targets]);

  const filteredTargets = useMemo(() => {
    const normalizedQuery = search.trim().toLowerCase();
    if (!normalizedQuery) {
      return availableTargets;
    }

    return availableTargets.filter((target) =>
      getAvailableTargetSearchText(target).includes(normalizedQuery),
    );
  }, [availableTargets, search]);

  const selectedCount = selectedTargets.size;

  if (!open) {
    return null;
  }

  return (
    <Panel className="space-y-4">
      <div>
        <h2 className="text-sm font-semibold text-foreground">
          {t('virtualModels.dialogs.addEntryTitle')}
        </h2>
        <p className="mt-1 text-sm text-muted-foreground">
          {t('virtualModels.dialogs.addEntryDescription', {
            name: model?.name ?? '',
          })}
        </p>
      </div>
      {availableTargets.length === 0 ? (
        <EmptyState
          title={t('virtualModels.entries.noAvailableTargetsTitle')}
          description={t('virtualModels.entries.noAvailableTargetsDescription')}
        />
      ) : (
        <div className="space-y-3">
          <div className="relative">
            <RiSearchLine className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              value={search}
              onChange={(event) => {
                setSearch(event.target.value);
                if (error) {
                  setError(null);
                }
              }}
              className="pl-9"
              placeholder={t('virtualModels.fields.searchPlaceholder')}
            />
          </div>
          <div className="max-h-96 space-y-2 overflow-y-auto rounded-xl border border-border/60 bg-muted/10 p-2">
            {filteredTargets.length === 0 ? (
              <div className="rounded-lg border border-dashed border-border/60 px-3 py-6 text-center text-sm text-muted-foreground">
                {t('virtualModels.entries.noSearchResults')}
              </div>
            ) : (
              filteredTargets.map((target) => {
                const isChecked = selectedTargets.has(target.target);
                const displayTarget = getAvailableTargetDialogTitle(target);

                return (
                  <label
                    key={target.target}
                    className="flex items-start gap-3 rounded-lg border border-transparent px-3 py-2 hover:border-border/60 hover:bg-muted/40"
                  >
                    <Checkbox
                      checked={isChecked}
                      onCheckedChange={(checked) => {
                        setSelectedTargets((current) => {
                          const next = new Set(current);
                          if (checked) {
                            next.add(target.target);
                          } else {
                            next.delete(target.target);
                          }
                          return next;
                        });
                        if (error) {
                          setError(null);
                        }
                      }}
                    />
                    <div className="min-w-0 flex-1">
                      <div className="flex min-w-0 items-center gap-2">
                        {target.kind === 'direct' ? (
                          <ProviderIcon
                            provider={target.provider}
                            className="size-4"
                          />
                        ) : (
                          <div className="flex size-4 items-center justify-center rounded-full bg-primary/10 text-[9px] font-semibold text-primary">
                            Q
                          </div>
                        )}
                        <span className="truncate font-mono text-sm font-medium text-foreground">
                          {displayTarget}
                        </span>
                      </div>
                    </div>
                  </label>
                );
              })
            )}
          </div>
          {error ? <p className="text-xs text-destructive">{error}</p> : null}
        </div>
      )}
      <div className="flex justify-end gap-2">
        <Button variant="outline" onClick={() => onOpenChange(false)}>
          {t('common.cancel')}
        </Button>
        <Button
          onClick={async () => {
            if (selectedCount === 0) {
              setError(t('virtualModels.validation.targetRequired'));
              return;
            }
            const orderedTargets = availableTargets
              .filter((target) => selectedTargets.has(target.target))
              .map((target) => target.target);
            await onSubmit(orderedTargets);
          }}
          disabled={busy || disabled || availableTargets.length === 0}
        >
          {t('virtualModels.actions.addSelected', {
            count: selectedCount,
          })}
        </Button>
      </div>
    </Panel>
  );
}

function ImportDialog({
  open,
  busy,
  disabled,
  onOpenChange,
  onSubmit,
}: {
  open: boolean;
  busy: boolean;
  disabled: boolean;
  onOpenChange: (open: boolean) => void;
  onSubmit: (payload: RawVirtualModelExportPayload) => Promise<void>;
}) {
  const { t } = useTranslation();
  const [value, setValue] = useState('');
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) {
      setValue('');
      setError(null);
    }
  }, [open]);

  if (!open) {
    return null;
  }

  return (
    <Panel className="space-y-4">
      <div>
        <h2 className="text-sm font-semibold text-foreground">
          {t('virtualModels.dialogs.importTitle')}
        </h2>
        <p className="mt-1 text-sm text-muted-foreground">
          {t('virtualModels.dialogs.importDescription')}
        </p>
      </div>
      <div className="space-y-2">
        <Textarea
          rows={16}
          value={value}
          onChange={(event) => {
            setValue(event.target.value);
            if (error) {
              setError(null);
            }
          }}
          placeholder={t('virtualModels.fields.importPlaceholder')}
        />
        {error ? <p className="text-xs text-destructive">{error}</p> : null}
      </div>
      <div className="flex justify-end gap-2">
        <Button variant="outline" onClick={() => onOpenChange(false)}>
          {t('common.cancel')}
        </Button>
        <Button
          onClick={async () => {
            let parsed: RawVirtualModelExportPayload;

            try {
              parsed = JSON.parse(value) as RawVirtualModelExportPayload;
            } catch {
              setError(t('virtualModels.validation.invalidJson'));
              return;
            }

            await onSubmit(parsed);
          }}
          disabled={busy || disabled}
        >
          {t('virtualModels.actions.import')}
        </Button>
      </div>
    </Panel>
  );
}

function ExportDialog({
  open,
  value,
  onOpenChange,
}: {
  open: boolean;
  value: string;
  onOpenChange: (open: boolean) => void;
}) {
  const { t } = useTranslation();

  if (!open) {
    return null;
  }

  return (
    <Panel className="space-y-4">
      <div>
        <h2 className="text-sm font-semibold text-foreground">
          {t('virtualModels.dialogs.exportTitle')}
        </h2>
        <p className="mt-1 text-sm text-muted-foreground">
          {t('virtualModels.dialogs.exportDescription')}
        </p>
      </div>
      <div className="space-y-3">
        <Textarea
          rows={16}
          value={value}
          readOnly
          className="font-mono text-xs"
        />
        <div className="flex justify-end">
          <CopyButton
            variant="outline"
            value={value}
            successMessage={t('virtualModels.messages.exportCopied')}
            errorMessage={t('virtualModels.messages.exportCopyFailed')}
          >
            {t('virtualModels.actions.copyExport')}
          </CopyButton>
        </div>
      </div>
      <div className="flex justify-end">
        <Button variant="outline" onClick={() => onOpenChange(false)}>
          {t('common.cancel')}
        </Button>
      </div>
    </Panel>
  );
}
