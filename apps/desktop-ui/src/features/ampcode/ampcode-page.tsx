import { Button } from '@quotio/ui/components/button';
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from '@quotio/ui/components/collapsible';
import { Input } from '@quotio/ui/components/input';
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectLabel,
  SelectTrigger,
  SelectValue,
} from '@quotio/ui/components/select';
import { Switch } from '@quotio/ui/components/switch';
import {
  RiAddLine,
  RiArrowDownSLine,
  RiDeleteBinLine,
  RiDownload2Line,
  RiRefreshLine,
  RiSaveLine,
  RiTerminalLine,
  RiUpload2Line,
} from '@remixicon/react';
import { useForm } from '@tanstack/react-form';
import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { AdminPageHeader } from '@/components/admin/admin-page-header';
import { ErrorState } from '@/components/admin/error-state';
import { HeaderActionsPortal } from '@/components/admin/header-actions-portal';
import { LoadingState } from '@/components/admin/loading-state';
import { Panel } from '@/components/admin/panel';
import { useToast } from '@/components/admin/toast-provider';
import { useModelInventoryTargetsQuery } from '../virtual-models/api';
import {
  useAmpCLISetupStatusQuery,
  useAmpCodeMutations,
  useAmpCodeQuery,
} from './api';
import type { AmpModelMapping } from './types';

const PREDEFINED_AMP_MODEL_SLOTS = [
  { key: 'smart', label: 'Smart', from: 'claude-opus-4.6' },
  { key: 'rush', label: 'Rush', from: 'claude-haiku-4.5' },
  { key: 'deep', label: 'Deep', from: 'gpt-5.4' },
  { key: 'review', label: 'Review', from: 'gemini-3.1-pro' },
  { key: 'search', label: 'Search', from: 'gemini-3-flash' },
  { key: 'oracle', label: 'Oracle', from: 'gpt-5.4' },
  { key: 'librarian', label: 'Librarian', from: 'claude-sonnet-4.6' },
  { key: 'look-at', label: 'Look At', from: 'gemini-3-flash' },
  { key: 'painter', label: 'Painter', from: 'gemini-3-pro-image' },
  { key: 'handoff', label: 'Handoff', from: 'gemini-3-flash' },
  { key: 'titling', label: 'Titling', from: 'claude-haiku-4.5' },
] as const;

const MANAGEMENT_AUTH_POLICIES = [
  'validate-known-client',
  'allow-any-bearer',
] as const;

const NONE_TARGET_VALUE = '__none__';
const AMP_CLI_PREVIEW_MAX_LINES = 320;
const AMP_CLI_PREVIEW_MAX_CHARS = 20000;

function clipAmpCLIFilePreview(content: string) {
  const normalized = content.replaceAll('\r\n', '\n');
  const lines = normalized.split('\n');
  const lineLimited = lines.slice(0, AMP_CLI_PREVIEW_MAX_LINES).join('\n');

  let text = lineLimited;
  let truncated = lines.length > AMP_CLI_PREVIEW_MAX_LINES;
  if (text.length > AMP_CLI_PREVIEW_MAX_CHARS) {
    text = text.slice(0, AMP_CLI_PREVIEW_MAX_CHARS);
    truncated = true;
  }

  return {
    text,
    truncated,
  };
}

function AmpCLIFileDiff({
  before,
  after,
  beforeLabel,
  afterLabel,
  emptyLabel,
  truncatedLabel,
}: {
  before: string;
  after: string;
  beforeLabel: string;
  afterLabel: string;
  emptyLabel: string;
  truncatedLabel: string;
}) {
  const beforePreview = clipAmpCLIFilePreview(before);
  const afterPreview = clipAmpCLIFilePreview(after);
  const hasTruncatedPreview = beforePreview.truncated || afterPreview.truncated;

  return (
    <div className="space-y-2">
      <div className="grid gap-2 lg:grid-cols-2">
        <div className="space-y-1">
          <p className="text-[11px] font-medium text-muted-foreground">
            {beforeLabel}
          </p>
          <pre className="max-h-72 overflow-auto rounded-md border border-border/70 bg-muted/30 p-2 font-mono text-[11px] text-muted-foreground">
            {beforePreview.text || emptyLabel}
          </pre>
        </div>
        <div className="space-y-1">
          <p className="text-[11px] font-medium text-muted-foreground">
            {afterLabel}
          </p>
          <pre className="max-h-72 overflow-auto rounded-md border border-border/70 bg-muted/30 p-2 font-mono text-[11px] text-muted-foreground">
            {afterPreview.text || emptyLabel}
          </pre>
        </div>
      </div>
      {hasTruncatedPreview ? (
        <p className="text-[11px] text-muted-foreground">{truncatedLabel}</p>
      ) : null}
    </div>
  );
}

type PredefinedMappingField = {
  slotKey: string;
  slotLabel: string;
  from: string;
  to: string;
};

type CustomMappingField = {
  rowId: string;
  from: string;
  to: string;
  regex: boolean;
};

type AmpCodeFormValues = {
  upstream_api_key_input: string;
  routing_mode: string;
  predefinedMappings: PredefinedMappingField[];
  customMappings: CustomMappingField[];
  restrict_management_to_localhost: boolean;
  management_auth_policy: string;
};

const ROUTING_MODES = [
  'prefer-local-then-amp',
  'prefer-amp-until-quota-exhausted',
] as const;

type TargetOption = {
  value: string;
  label: string;
  provider: string;
  kind: 'direct' | 'virtual';
  modelId: string;
};

function groupTargetOptions(options: TargetOption[], filterText: string) {
  const normalizedFilter = filterText.trim().toLowerCase();

  const filtered = options.filter((option) => {
    if (!normalizedFilter) {
      return true;
    }

    const searchText = [
      option.label,
      option.value,
      option.provider,
      option.modelId,
      option.kind,
    ]
      .join(' ')
      .toLowerCase();

    return searchText.includes(normalizedFilter);
  });

  const virtual = filtered.filter((option) => option.kind === 'virtual');
  const providerMap = new Map<string, TargetOption[]>();

  for (const option of filtered) {
    if (option.kind === 'virtual') {
      continue;
    }

    const provider = option.provider || 'unknown';
    const group = providerMap.get(provider) ?? [];
    group.push(option);
    providerMap.set(provider, group);
  }

  const providers = Array.from(providerMap.entries()).sort((left, right) =>
    left[0].localeCompare(right[0]),
  );

  return {
    total: filtered.length,
    virtual,
    providers,
  };
}

function MappingTargetSelect({
  value,
  onValueChange,
  options,
  includeNone,
  isLoading,
  placeholder,
  t,
  triggerClassName,
}: {
  value: string;
  onValueChange: (nextValue: string) => void;
  options: TargetOption[];
  includeNone: boolean;
  isLoading: boolean;
  placeholder: string;
  t: (key: string, options?: Record<string, unknown>) => string;
  triggerClassName: string;
}) {
  const [filter, setFilter] = useState('');
  const groupedTargets = groupTargetOptions(options, filter);

  return (
    <Select
      value={value}
      onValueChange={(nextValue) => {
        if (includeNone && nextValue === NONE_TARGET_VALUE) {
          onValueChange('');
          return;
        }

        onValueChange(nextValue ?? '');
      }}
      onOpenChange={(open) => {
        if (!open) {
          setFilter('');
        }
      }}
    >
      <SelectTrigger className={triggerClassName}>
        <SelectValue
          placeholder={
            isLoading ? t('ampcode.labels.loadingTargets') : placeholder
          }
        />
      </SelectTrigger>
      <SelectContent>
        <div className="sticky top-0 z-10 border-b border-border/50 bg-popover/95 p-2">
          <Input
            value={filter}
            onChange={(event) => setFilter(event.target.value)}
            placeholder={t('ampcode.fields.targetFilterPlaceholder')}
            className="h-8 text-xs"
          />
        </div>

        {includeNone ? (
          <SelectItem value={NONE_TARGET_VALUE}>
            {t('ampcode.labels.none')}
          </SelectItem>
        ) : null}

        {groupedTargets.virtual.length > 0 ? (
          <SelectGroup>
            <SelectLabel>{t('ampcode.labels.virtualModelsGroup')}</SelectLabel>
            {groupedTargets.virtual.map((option) => (
              <SelectItem key={option.value} value={option.value}>
                {option.label}
              </SelectItem>
            ))}
          </SelectGroup>
        ) : null}

        {groupedTargets.providers.map(([provider, providerOptions]) => (
          <SelectGroup key={provider}>
            <SelectLabel>{provider}</SelectLabel>
            {providerOptions.map((option) => (
              <SelectItem key={option.value} value={option.value}>
                {option.label}
              </SelectItem>
            ))}
          </SelectGroup>
        ))}

        {groupedTargets.total === 0 ? (
          <div className="px-3 py-2 text-xs text-muted-foreground">
            {t('ampcode.labels.noTargetsFound')}
          </div>
        ) : null}
      </SelectContent>
    </Select>
  );
}

function parseTargetLabel(target: {
  kind?: string;
  provider?: string;
  modelId?: string;
  label?: string;
  target?: string;
}) {
  if (target.label?.trim()) {
    return target.label.trim();
  }

  if (target.kind === 'virtual') {
    return `quotio/${target.modelId ?? target.target ?? ''}`;
  }

  if (target.provider && target.modelId) {
    return `${target.provider}/${target.modelId}`;
  }

  return target.target ?? '';
}

function createCustomMappingRow(
  value?: Partial<Pick<CustomMappingField, 'from' | 'to' | 'regex'>>,
): CustomMappingField {
  return {
    rowId: `custom-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`,
    from: value?.from ?? '',
    to: value?.to ?? '',
    regex: Boolean(value?.regex),
  };
}

function createEmptyFormValues(): AmpCodeFormValues {
  return {
    upstream_api_key_input: '',
    routing_mode: 'prefer-local-then-amp',
    predefinedMappings: PREDEFINED_AMP_MODEL_SLOTS.map((slot) => ({
      slotKey: slot.key,
      slotLabel: slot.label,
      from: slot.from,
      to: '',
    })),
    customMappings: [],
    restrict_management_to_localhost: true,
    management_auth_policy: 'validate-known-client',
  };
}

function normalizeAmpCodeToForm(
  ampcode:
    | {
        model_mappings?: AmpModelMapping[];
        routing_mode?: string;
        restrict_management_to_localhost?: boolean;
        management_auth_policy?: string;
      }
    | null
    | undefined,
) {
  const defaults = createEmptyFormValues();
  const mappings = ampcode?.model_mappings ?? [];

  const predefinedMappings = PREDEFINED_AMP_MODEL_SLOTS.map((slot) => {
    const matched = mappings.find(
      (mapping) => !mapping.regex && mapping.from === slot.from,
    );

    return {
      slotKey: slot.key,
      slotLabel: slot.label,
      from: slot.from,
      to: matched?.to ?? '',
    } satisfies PredefinedMappingField;
  });

  const predefinedFromSet = new Set<string>(
    predefinedMappings.map((mapping) => mapping.from),
  );
  const consumedPredefined = new Set<string>(
    predefinedMappings
      .filter((mapping) => mapping.to)
      .map((mapping) => mapping.from),
  );

  const customMappings = mappings
    .filter((mapping) => {
      if (mapping.regex) {
        return true;
      }

      return !(
        predefinedFromSet.has(mapping.from) &&
        consumedPredefined.has(mapping.from)
      );
    })
    .map((mapping) =>
      createCustomMappingRow({
        from: mapping.from,
        to: mapping.to,
        regex: Boolean(mapping.regex),
      }),
    );

  const authPolicy = MANAGEMENT_AUTH_POLICIES.includes(
    (ampcode?.management_auth_policy ??
      '') as (typeof MANAGEMENT_AUTH_POLICIES)[number],
  )
    ? (ampcode?.management_auth_policy as string)
    : defaults.management_auth_policy;

  const routingMode = ROUTING_MODES.includes(
    (ampcode?.routing_mode ?? '') as (typeof ROUTING_MODES)[number],
  )
    ? (ampcode?.routing_mode as string)
    : defaults.routing_mode;

  return {
    upstream_api_key_input: '',
    routing_mode: routingMode,
    predefinedMappings,
    customMappings,
    restrict_management_to_localhost: Boolean(
      ampcode?.restrict_management_to_localhost ?? true,
    ),
    management_auth_policy: authPolicy,
  } satisfies AmpCodeFormValues;
}

function isValidRegexPattern(value: string) {
  try {
    new RegExp(value);
    return true;
  } catch {
    return false;
  }
}

function buildValidationErrors(
  values: AmpCodeFormValues,
  t: (key: string, options?: Record<string, unknown>) => string,
) {
  const predefinedFromSet = new Set(
    values.predefinedMappings.map((mapping) => mapping.from),
  );

  const customErrors = values.customMappings.map((mapping) => {
    const errors: {
      from?: string;
      to?: string;
      regex?: string;
    } = {};

    const normalizedFrom = mapping.from.trim();
    const normalizedTo = mapping.to.trim();

    if (!normalizedFrom) {
      errors.from = t('ampcode.validation.customFromRequired');
    }

    if (!normalizedTo) {
      errors.to = t('ampcode.validation.customToRequired');
    }

    if (
      mapping.regex &&
      normalizedFrom &&
      !isValidRegexPattern(normalizedFrom)
    ) {
      errors.from = t('ampcode.validation.invalidRegex');
    }

    if (
      !mapping.regex &&
      normalizedFrom &&
      predefinedFromSet.has(normalizedFrom)
    ) {
      errors.from = t('ampcode.validation.duplicateWithPredefined');
    }

    return errors;
  });

  const nonRegexCustomIndexesByFrom = new Map<string, number[]>();
  values.customMappings.forEach((mapping, index) => {
    if (mapping.regex) {
      return;
    }

    const normalizedFrom = mapping.from.trim();
    if (!normalizedFrom) {
      return;
    }

    const indexes = nonRegexCustomIndexesByFrom.get(normalizedFrom) ?? [];
    indexes.push(index);
    nonRegexCustomIndexesByFrom.set(normalizedFrom, indexes);
  });

  for (const indexes of nonRegexCustomIndexesByFrom.values()) {
    if (indexes.length < 2) {
      continue;
    }

    for (const index of indexes) {
      customErrors[index].from = t('ampcode.validation.duplicateCustomFrom');
    }
  }

  const hasCustomErrors = customErrors.some((error) =>
    Boolean(error.from || error.to || error.regex),
  );

  if (!hasCustomErrors) {
    return undefined;
  }

  return {
    fields: {
      customMappings: customErrors,
    },
  };
}

function buildPayloadModelMappings(
  values: AmpCodeFormValues,
): AmpModelMapping[] {
  const predefined = values.predefinedMappings
    .filter((mapping) => mapping.to.trim())
    .map((mapping) => ({
      from: mapping.from,
      to: mapping.to.trim(),
      regex: false,
    }));

  const custom = values.customMappings
    .map((mapping) => ({
      from: mapping.from.trim(),
      to: mapping.to.trim(),
      regex: Boolean(mapping.regex),
    }))
    .filter((mapping) => mapping.from && mapping.to);

  return [...predefined, ...custom];
}

export function AmpCodePage({ embedded = false }: { embedded?: boolean }) {
  const { t } = useTranslation();
  const toast = useToast();
  const [isDiffDialogOpen, setIsDiffDialogOpen] = useState(false);
  const query = useAmpCodeQuery();
  const ampCLISetupQuery = useAmpCLISetupStatusQuery();
  const targetsQuery = useModelInventoryTargetsQuery();
  const mutations = useAmpCodeMutations();

  const form = useForm({
    defaultValues: createEmptyFormValues(),
    validators: {
      onSubmit: ({ value }) => buildValidationErrors(value, t),
    },
    onSubmit: async ({ value }) => {
      await mutations.saveModelMappingsMutation.mutateAsync(
        buildPayloadModelMappings(value),
      );
      if (value.upstream_api_key_input.trim()) {
        await mutations.saveUpstreamAPIKeyMutation.mutateAsync(
          value.upstream_api_key_input.trim(),
        );
      }
      await mutations.saveRoutingModeMutation.mutateAsync(value.routing_mode);
      await mutations.saveRestrictLocalhostMutation.mutateAsync(
        value.restrict_management_to_localhost,
      );
      await mutations.saveManagementAuthPolicyMutation.mutateAsync(
        value.management_auth_policy,
      );
      toast.success(t('ampcode.messages.saved'));
    },
  });

  useEffect(() => {
    const ampcode = query.data?.ampcode;
    if (!ampcode) {
      return;
    }

    if (form.state.isDirty) {
      return;
    }

    form.reset(normalizeAmpCodeToForm(ampcode));
  }, [form, query.data]);

  if (query.isLoading) {
    return <LoadingState label={t('ampcode.loading')} />;
  }

  if (query.error) {
    return (
      <ErrorState
        title={t('ampcode.failedToLoad')}
        description={
          query.error instanceof Error
            ? query.error.message
            : t('common.unknownError')
        }
        actionLabel={t('common.retry')}
        onAction={() => void query.refetch()}
      />
    );
  }

  const isSaving =
    mutations.saveModelMappingsMutation.isPending ||
    mutations.saveUpstreamAPIKeyMutation.isPending ||
    mutations.saveRoutingModeMutation.isPending ||
    mutations.saveRestrictLocalhostMutation.isPending ||
    mutations.saveManagementAuthPolicyMutation.isPending;

  const isApplyingCLISetup = mutations.ampCLISetupApplyMutation.isPending;
  const isRollingBackCLISetup = mutations.ampCLISetupRollbackMutation.isPending;
  const isDiffingCLISetup = mutations.ampCLISetupDiffMutation.isPending;

  const ampCLISetup = ampCLISetupQuery.data?.cli_setup;
  const latestDiffResponse = mutations.ampCLISetupDiffMutation.data;
  const latestDiffFiles = (latestDiffResponse?.plan.files ?? []).filter(
    (file) => file.has_changes,
  );

  const maskedUpstreamKey = query.data?.ampcode.upstream_api_key ?? '';
  const effectiveUpstreamURL =
    query.data?.ampcode.effective_upstream_url ??
    ampCLISetup?.effective_upstream_url ??
    'https://ampcode.com';

  const targetOptions: TargetOption[] = (targetsQuery.data?.models ?? []).map(
    (target) => ({
      value: target.target,
      label: parseTargetLabel(target),
      provider: target.provider,
      kind: target.kind,
      modelId: target.modelId,
    }),
  );

  const targetLookup = new Map(
    targetOptions.map((option) => [option.value, option.label]),
  );

  const headerActions = (
    <div className="flex items-center gap-2">
      <Button
        variant="outline"
        size="sm"
        onClick={() => void query.refetch()}
        disabled={query.isRefetching}
      >
        <RiRefreshLine />
        {t('common.refresh')}
      </Button>
      <Button
        type="submit"
        form="ampcode-settings-form"
        size="sm"
        disabled={isSaving || targetsQuery.isLoading}
      >
        <RiSaveLine />
        {t('ampcode.actions.saveChanges')}
      </Button>
    </div>
  );

  return (
    <div className="flex h-full flex-col gap-4">
      {embedded ? (
        <HeaderActionsPortal>{headerActions}</HeaderActionsPortal>
      ) : (
        <AdminPageHeader
          title={t('ampcode.title')}
          description={t('ampcode.description')}
          actions={headerActions}
        />
      )}

      <form
        id="ampcode-settings-form"
        className="space-y-3"
        onSubmit={(event) => {
          event.preventDefault();
          event.stopPropagation();
          void form.handleSubmit().catch((error: unknown) => {
            toast.error(
              error instanceof Error ? error.message : t('common.unknownError'),
            );
          });
        }}
      >
        <Panel className="space-y-3 p-3">
          <div className="space-y-1">
            <h2 className="text-sm font-semibold text-foreground">
              {t('ampcode.sections.cliSetup')}
            </h2>
            <p className="text-xs text-muted-foreground">
              {t('ampcode.sections.cliSetupDesc')}
            </p>
          </div>

          {ampCLISetupQuery.isLoading ? (
            <p className="text-xs text-muted-foreground">
              {t('ampcode.labels.loadingCLISetupStatus')}
            </p>
          ) : ampCLISetupQuery.error ? (
            <p className="text-xs text-destructive">
              {ampCLISetupQuery.error instanceof Error
                ? ampCLISetupQuery.error.message
                : t('common.unknownError')}
            </p>
          ) : ampCLISetup ? (
            <>
              <div className="rounded-md border border-amber-300/50 bg-amber-500/5 px-3 py-2 text-xs text-amber-900 dark:text-amber-100">
                <p className="font-medium">
                  {t('ampcode.labels.serverMachineScope')}
                </p>
                <p>{ampCLISetup.scope_warning}</p>
                <p className="mt-1 text-[11px] text-muted-foreground">
                  {ampCLISetup.machine_scope_description}
                </p>
              </div>

              <div className="grid gap-2 md:grid-cols-2">
                <div className="rounded-md border border-border px-3 py-2">
                  <p className="text-xs font-medium text-foreground">
                    {t('ampcode.labels.setupState')}
                  </p>
                  <p className="text-xs text-muted-foreground">
                    {ampCLISetup.installed
                      ? t('ampcode.labels.installedByQuotio')
                      : t('ampcode.labels.notInstalledByQuotio')}
                  </p>
                </div>
                <div className="rounded-md border border-border px-3 py-2">
                  <p className="text-xs font-medium text-foreground">
                    {t('ampcode.labels.rollbackManifest')}
                  </p>
                  <p className="break-all font-mono text-[11px] text-muted-foreground">
                    {ampCLISetup.latest_manifest || t('ampcode.labels.none')}
                  </p>
                </div>
                <div className="rounded-md border border-border px-3 py-2">
                  <p className="text-xs font-medium text-foreground">
                    {t('ampcode.labels.serverHomeDirectory')}
                  </p>
                  <p className="break-all font-mono text-[11px] text-muted-foreground">
                    {ampCLISetup.home_dir}
                  </p>
                </div>
                <div className="rounded-md border border-border px-3 py-2">
                  <p className="text-xs font-medium text-foreground">
                    {t('ampcode.labels.quotioBaseURL')}
                  </p>
                  <p className="break-all font-mono text-[11px] text-muted-foreground">
                    {ampCLISetup.base_url}
                  </p>
                </div>
                <div className="rounded-md border border-border px-3 py-2 md:col-span-2">
                  <p className="text-xs font-medium text-foreground">
                    {t('ampcode.labels.effectiveUpstreamURL')}
                  </p>
                  <p className="break-all font-mono text-[11px] text-muted-foreground">
                    {ampCLISetup.effective_upstream_url}
                  </p>
                  <p className="mt-1 text-[11px] text-muted-foreground">
                    {ampCLISetup.upstream_access_note}
                  </p>
                </div>
              </div>

              <div className="space-y-1">
                <p className="text-xs font-medium text-foreground">
                  {t('ampcode.labels.targetFiles')}
                </p>
                <ul className="space-y-1">
                  {ampCLISetup.target_paths.map((targetPath) => (
                    <li
                      key={targetPath}
                      className="break-all rounded-md border border-border px-2 py-1 font-mono text-[11px] text-muted-foreground"
                    >
                      {targetPath}
                    </li>
                  ))}
                </ul>
              </div>

              <div className="flex flex-wrap items-center gap-2">
                <Button
                  type="button"
                  size="sm"
                  onClick={() => {
                    void mutations.ampCLISetupApplyMutation
                      .mutateAsync()
                      .then((result) => {
                        mutations.ampCLISetupDiffMutation.reset();
                        toast.success(result.summary);
                      })
                      .catch((error: unknown) => {
                        toast.error(
                          error instanceof Error
                            ? error.message
                            : t('common.unknownError'),
                        );
                      });
                  }}
                  disabled={
                    isApplyingCLISetup ||
                    isRollingBackCLISetup ||
                    ampCLISetupQuery.isLoading
                  }
                >
                  <RiUpload2Line />
                  {isApplyingCLISetup
                    ? t('ampcode.actions.applyingSettings')
                    : t('ampcode.actions.applySettings')}
                </Button>

                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  onClick={() => {
                    void mutations.ampCLISetupRollbackMutation
                      .mutateAsync()
                      .then((result) => {
                        mutations.ampCLISetupDiffMutation.reset();
                        toast.success(result.summary);
                      })
                      .catch((error: unknown) => {
                        toast.error(
                          error instanceof Error
                            ? error.message
                            : t('common.unknownError'),
                        );
                      });
                  }}
                  disabled={
                    isApplyingCLISetup ||
                    isRollingBackCLISetup ||
                    !ampCLISetup.rollback_available
                  }
                >
                  <RiDownload2Line />
                  {isRollingBackCLISetup
                    ? t('ampcode.actions.rollingBackSettings')
                    : t('ampcode.actions.rollbackSettings')}
                </Button>

                <Button
                  type="button"
                  size="sm"
                  variant="ghost"
                  onClick={() => {
                    setIsDiffDialogOpen(true);
                    void mutations.ampCLISetupDiffMutation
                      .mutateAsync()
                      .catch((error: unknown) => {
                        toast.error(
                          error instanceof Error
                            ? error.message
                            : t('common.unknownError'),
                        );
                      });
                  }}
                  disabled={
                    isApplyingCLISetup ||
                    isRollingBackCLISetup ||
                    isDiffingCLISetup
                  }
                >
                  <RiRefreshLine />
                  {isDiffingCLISetup
                    ? t('ampcode.actions.previewingDiff')
                    : t('ampcode.actions.previewDiff')}
                </Button>
              </div>

              {!ampCLISetup.rollback_available ? (
                <p className="text-xs text-muted-foreground">
                  {t('ampcode.labels.rollbackUnavailable')}
                </p>
              ) : null}

              {isDiffDialogOpen ? (
                <Panel className="space-y-4">
                  <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                    <div>
                      <h3 className="text-sm font-semibold text-foreground">
                        {t('ampcode.labels.latestDiffPreview')}
                      </h3>
                      <p className="mt-1 text-sm text-muted-foreground">
                        {latestDiffResponse?.summary ??
                          t('ampcode.labels.diffDialogDescription')}
                      </p>
                    </div>
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      onClick={() => {
                        setIsDiffDialogOpen(false);
                        mutations.ampCLISetupDiffMutation.reset();
                      }}
                    >
                      {t('common.close')}
                    </Button>
                  </div>

                  {isDiffingCLISetup ? (
                    <p className="text-xs text-muted-foreground">
                      {t('ampcode.actions.previewingDiff')}
                    </p>
                  ) : null}

                  {!isDiffingCLISetup && latestDiffFiles.length === 0 ? (
                    <p className="text-xs text-muted-foreground">
                      {t('ampcode.labels.noDiffChanges')}
                    </p>
                  ) : null}

                  {latestDiffFiles.map((file) => (
                    <div
                      key={file.target_path}
                      className="mt-3 space-y-2 rounded-md border border-border/70 bg-muted/20 p-2"
                    >
                      <p className="break-all font-mono text-[11px] text-muted-foreground">
                        {file.target_path}
                      </p>
                      <div className="overflow-auto rounded-md border border-border/70 bg-background">
                        <AmpCLIFileDiff
                          before={file.before ?? ''}
                          after={file.after ?? ''}
                          beforeLabel={t('ampcode.labels.diffBefore')}
                          afterLabel={t('ampcode.labels.diffAfter')}
                          emptyLabel={t('ampcode.labels.emptyFile')}
                          truncatedLabel={t(
                            'ampcode.labels.diffPreviewTruncated',
                          )}
                        />
                      </div>
                    </div>
                  ))}
                </Panel>
              ) : null}

              <Collapsible>
                <CollapsibleTrigger
                  render={<Button type="button" variant="outline" size="sm" />}
                >
                  <RiTerminalLine />
                  {t('ampcode.actions.showManualSetup')}
                  <RiArrowDownSLine className="ml-1" />
                </CollapsibleTrigger>
                <CollapsibleContent>
                  <div className="mt-2 space-y-2 rounded-md border border-border px-3 py-3">
                    <p className="text-xs text-muted-foreground">
                      {ampCLISetup.manual_setup_description}
                    </p>
                    <p className="text-xs text-muted-foreground">
                      {ampCLISetup.client_bearer_description}
                    </p>

                    <p className="text-xs font-medium text-foreground">
                      {t('ampcode.labels.manualFileSetup')}
                    </p>
                    <ul className="space-y-1">
                      <li className="font-mono text-[11px] text-muted-foreground">
                        {ampCLISetup.settings_path}
                      </li>
                      <li className="font-mono text-[11px] text-muted-foreground">
                        {ampCLISetup.secrets_path}
                      </li>
                    </ul>

                    <pre className="overflow-auto rounded-md border border-border/70 bg-muted/40 p-2 font-mono text-[11px] text-muted-foreground">
                      {ampCLISetup.settings_snippet}
                    </pre>
                    <pre className="overflow-auto rounded-md border border-border/70 bg-muted/40 p-2 font-mono text-[11px] text-muted-foreground">
                      {ampCLISetup.secrets_snippet}
                    </pre>

                    <p className="text-xs font-medium text-foreground">
                      {t('ampcode.labels.manualEnvSetup')}
                    </p>
                    <ul className="space-y-1">
                      {ampCLISetup.env_var_names.map((name) => (
                        <li
                          key={name}
                          className="font-mono text-[11px] text-muted-foreground"
                        >
                          {name}
                        </li>
                      ))}
                    </ul>
                    <pre className="overflow-auto rounded-md border border-border/70 bg-muted/40 p-2 font-mono text-[11px] text-muted-foreground">
                      {ampCLISetup.env_snippet}
                    </pre>

                    {ampCLISetup.amp_login_not_required ? (
                      <p className="text-xs text-muted-foreground">
                        {t('ampcode.labels.ampLoginNotRequired')}
                      </p>
                    ) : null}
                  </div>
                </CollapsibleContent>
              </Collapsible>
            </>
          ) : null}
        </Panel>

        <div className="grid gap-3 xl:grid-cols-[1.8fr_1fr]">
          <Panel className="space-y-3 p-3 xl:col-span-2">
            <div className="space-y-1">
              <h2 className="text-sm font-semibold text-foreground">
                {t('ampcode.sections.upstreamAccess')}
              </h2>
              <p className="text-xs text-muted-foreground">
                {t('ampcode.sections.upstreamAccessDesc')}
              </p>
            </div>

            <div className="grid gap-3 md:grid-cols-2">
              <div className="space-y-1 rounded-md border border-border px-3 py-2 md:col-span-2">
                <p className="text-xs font-medium text-foreground">
                  {t('ampcode.labels.effectiveUpstreamURL')}
                </p>
                <p className="break-all font-mono text-[11px] text-muted-foreground">
                  {effectiveUpstreamURL}
                </p>
                <p className="text-xs text-muted-foreground">
                  {t('ampcode.labels.effectiveUpstreamURLHelp')}
                </p>
              </div>

              <form.Field name="upstream_api_key_input">
                {(field) => (
                  <div className="space-y-1">
                    <label className="text-xs font-medium text-foreground">
                      {t('ampcode.fields.upstreamApiKey')}
                    </label>
                    <Input
                      value={field.state.value}
                      onChange={(event) =>
                        field.handleChange(event.target.value)
                      }
                      placeholder={t(
                        'ampcode.fields.upstreamApiKeyPlaceholder',
                      )}
                      className="h-8 text-xs"
                    />
                    <p className="text-xs text-muted-foreground">
                      {t('ampcode.fields.upstreamApiKeyHelp')}
                    </p>
                    <p className="text-xs text-muted-foreground">
                      {t('ampcode.fields.clientBearerHelp')}
                    </p>
                    <p className="font-mono text-[11px] text-muted-foreground">
                      {t('ampcode.labels.currentUpstreamKey', {
                        key: maskedUpstreamKey || t('ampcode.labels.none'),
                      })}
                    </p>
                    <Button
                      type="button"
                      size="sm"
                      variant="outline"
                      onClick={() =>
                        void mutations.clearUpstreamAPIKeyMutation
                          .mutateAsync()
                          .then(() =>
                            toast.success(t('ampcode.messages.saved')),
                          )
                          .catch((error: unknown) => {
                            toast.error(
                              error instanceof Error
                                ? error.message
                                : t('common.unknownError'),
                            );
                          })
                      }
                      disabled={mutations.clearUpstreamAPIKeyMutation.isPending}
                    >
                      {t('ampcode.actions.clearUpstreamApiKey')}
                    </Button>
                  </div>
                )}
              </form.Field>

              <form.Field name="routing_mode">
                {(field) => (
                  <label className="block space-y-1 rounded-md border border-border px-3 py-2 text-sm">
                    <span className="font-medium text-foreground">
                      {t('ampcode.fields.routingMode')}
                    </span>
                    <Select
                      value={field.state.value}
                      onValueChange={(value) =>
                        field.handleChange(value ?? 'prefer-local-then-amp')
                      }
                    >
                      <SelectTrigger className="h-8 w-full rounded-md text-xs">
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="prefer-local-then-amp">
                          {t('ampcode.options.preferLocalThenAmp')}
                        </SelectItem>
                        <SelectItem value="prefer-amp-until-quota-exhausted">
                          {t('ampcode.options.preferAmpUntilQuotaExhausted')}
                        </SelectItem>
                      </SelectContent>
                    </Select>
                    <p className="text-xs text-muted-foreground">
                      {t('ampcode.fields.routingModeHelp')}
                    </p>
                  </label>
                )}
              </form.Field>
            </div>
          </Panel>

          <Panel className="space-y-3 p-3">
            <div className="space-y-1">
              <h2 className="text-sm font-semibold text-foreground">
                {t('ampcode.sections.modelMappings')}
              </h2>
              <p className="text-xs text-muted-foreground">
                {t('ampcode.sections.modelMappingsDesc')}
              </p>
            </div>

            <div className="grid grid-cols-[9rem_minmax(0,1fr)_minmax(0,1fr)] gap-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">
              <div>{t('ampcode.fields.slot')}</div>
              <div>{t('ampcode.fields.from')}</div>
              <div>{t('ampcode.fields.to')}</div>
            </div>

            <form.Field name="predefinedMappings" mode="array">
              {(field) => (
                <div className="space-y-1.5">
                  {field.state.value.map((mapping, index) => (
                    <div
                      key={mapping.slotKey}
                      className="grid grid-cols-[9rem_minmax(0,1fr)_minmax(0,1fr)] items-center gap-2 rounded-md border border-border px-2 py-1.5"
                    >
                      <div className="text-xs font-medium text-foreground">
                        {mapping.slotLabel}
                      </div>
                      <div className="truncate font-mono text-xs text-muted-foreground">
                        {mapping.from}
                      </div>
                      <MappingTargetSelect
                        value={mapping.to}
                        onValueChange={(nextValue) =>
                          field.replaceValue(index, {
                            ...mapping,
                            to: nextValue,
                          })
                        }
                        options={targetOptions}
                        includeNone
                        isLoading={targetsQuery.isLoading}
                        placeholder={t('ampcode.labels.selectTarget')}
                        t={t}
                        triggerClassName="h-8 w-full rounded-md text-xs"
                      />
                    </div>
                  ))}
                </div>
              )}
            </form.Field>

            <div className="space-y-2 rounded-md border border-border p-2">
              <div className="space-y-0.5">
                <h3 className="text-sm font-semibold text-foreground">
                  {t('ampcode.sections.customMappings')}
                </h3>
                <p className="text-xs text-muted-foreground">
                  {t('ampcode.sections.customMappingsDesc')}
                </p>
              </div>

              <form.Field name="customMappings" mode="array">
                {(field) => {
                  const customErrors = Array.isArray(field.state.meta.errors)
                    ? field.state.meta.errors
                    : [];

                  return (
                    <div className="space-y-1.5">
                      {field.state.value.map((mapping, index) => {
                        const rowError =
                          customErrors[index] &&
                          typeof customErrors[index] === 'object'
                            ? (customErrors[index] as {
                                from?: string;
                                to?: string;
                              })
                            : undefined;

                        return (
                          <div key={mapping.rowId} className="space-y-1">
                            <div className="grid grid-cols-[minmax(0,1.2fr)_minmax(0,1.2fr)_auto_auto] items-center gap-1.5 rounded-md border border-border px-1.5 py-1.5">
                              <Input
                                value={mapping.from}
                                onChange={(event) =>
                                  field.replaceValue(index, {
                                    ...mapping,
                                    from: event.target.value,
                                  })
                                }
                                placeholder={t(
                                  'ampcode.fields.customFromPlaceholder',
                                )}
                                className="h-8 text-xs"
                              />
                              <MappingTargetSelect
                                value={mapping.to}
                                onValueChange={(nextValue) =>
                                  field.replaceValue(index, {
                                    ...mapping,
                                    to: nextValue,
                                  })
                                }
                                options={targetOptions}
                                includeNone={false}
                                isLoading={targetsQuery.isLoading}
                                placeholder={t('ampcode.labels.selectTarget')}
                                t={t}
                                triggerClassName="h-8 w-full rounded-md text-xs"
                              />
                              <label className="flex h-8 items-center gap-1 rounded-md border border-border px-2 text-xs text-foreground">
                                <Switch
                                  checked={mapping.regex}
                                  onCheckedChange={(checked) =>
                                    field.replaceValue(index, {
                                      ...mapping,
                                      regex: Boolean(checked),
                                    })
                                  }
                                  aria-label={t('ampcode.fields.regex')}
                                />
                                {t('ampcode.fields.regex')}
                              </label>
                              <Button
                                type="button"
                                variant="outline"
                                size="icon-sm"
                                onClick={() => field.removeValue(index)}
                                aria-label={t(
                                  'ampcode.actions.removeCustomMapping',
                                )}
                              >
                                <RiDeleteBinLine />
                              </Button>
                            </div>

                            {rowError?.from ? (
                              <p className="text-xs text-destructive">
                                {rowError.from}
                              </p>
                            ) : null}
                            {rowError?.to ? (
                              <p className="text-xs text-destructive">
                                {rowError.to}
                              </p>
                            ) : null}
                            {mapping.to && targetLookup.has(mapping.to) ? (
                              <p className="text-[11px] text-muted-foreground">
                                {t('ampcode.labels.selectedTarget', {
                                  target: targetLookup.get(mapping.to),
                                })}
                              </p>
                            ) : null}
                          </div>
                        );
                      })}

                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        onClick={() =>
                          field.pushValue(createCustomMappingRow())
                        }
                      >
                        <RiAddLine />
                        {t('ampcode.actions.addCustomMapping')}
                      </Button>
                    </div>
                  );
                }}
              </form.Field>
            </div>
          </Panel>

          <Panel className="space-y-3 p-3">
            <div className="space-y-1">
              <h2 className="text-sm font-semibold text-foreground">
                {t('ampcode.sections.security')}
              </h2>
              <p className="text-xs text-muted-foreground">
                {t('ampcode.sections.securityDesc')}
              </p>
            </div>

            <div className="space-y-2">
              <form.Field name="restrict_management_to_localhost">
                {(field) => (
                  <label className="flex items-start justify-between gap-3 rounded-md border border-border px-3 py-2">
                    <div className="space-y-0.5">
                      <div className="text-sm font-medium text-foreground">
                        {t('ampcode.fields.restrictLocalhost')}
                      </div>
                      <p className="text-xs text-muted-foreground">
                        {t('ampcode.fields.restrictLocalhostHelp')}
                      </p>
                    </div>
                    <Switch
                      checked={field.state.value}
                      onCheckedChange={(checked) =>
                        field.handleChange(Boolean(checked))
                      }
                      aria-label={t('ampcode.fields.restrictLocalhost')}
                    />
                  </label>
                )}
              </form.Field>

              <form.Field name="management_auth_policy">
                {(field) => (
                  <label className="block space-y-1 rounded-md border border-border px-3 py-2 text-sm">
                    <span className="font-medium text-foreground">
                      {t('ampcode.fields.managementAuthPolicy')}
                    </span>
                    <Select
                      value={field.state.value}
                      onValueChange={(value) =>
                        field.handleChange(value ?? 'validate-known-client')
                      }
                    >
                      <SelectTrigger className="h-8 w-full rounded-md text-xs">
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="validate-known-client">
                          {t('ampcode.options.validateKnownClient')}
                        </SelectItem>
                        <SelectItem value="allow-any-bearer">
                          {t('ampcode.options.allowAnyBearer')}
                        </SelectItem>
                      </SelectContent>
                    </Select>
                    <p className="text-xs text-muted-foreground">
                      {t('ampcode.fields.managementAuthPolicyHelp')}
                    </p>
                  </label>
                )}
              </form.Field>
            </div>
          </Panel>
        </div>

        <div className="flex items-center justify-between">
          <p className="text-xs text-muted-foreground">
            {t('ampcode.labels.availableTargetsCount', {
              count: targetOptions.length,
            })}
          </p>
        </div>
      </form>
    </div>
  );
}
