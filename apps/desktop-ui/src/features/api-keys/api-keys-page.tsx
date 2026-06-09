import { Badge } from '@quotio/ui/components/badge';
import { Button } from '@quotio/ui/components/button';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@quotio/ui/components/dialog';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@quotio/ui/components/dropdown-menu';
import { Input } from '@quotio/ui/components/input';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@quotio/ui/components/select';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@quotio/ui/components/table';
import {
  RiAddLine,
  RiDeleteBinLine,
  RiEdit2Line,
  RiKey2Line,
  RiMore2Fill,
  RiRefreshLine,
  RiSearchLine,
  RiShutDownLine,
} from '@remixicon/react';
import { useNavigate } from '@tanstack/react-router';
import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { AdminPageHeader } from '@/components/admin/admin-page-header';
import { CopyButton } from '@/components/admin/copy-button';
import { EmptyState } from '@/components/admin/empty-state';
import { ErrorState } from '@/components/admin/error-state';
import { LoadingState } from '@/components/admin/loading-state';
import { Panel } from '@/components/admin/panel';
import { useToast } from '@/components/admin/toast-provider';
import { useAdminRuntime } from '@/lib/admin/runtime';
import {
  type APIKeyListFilters,
  useClientKeyMutations,
  useClientKeysQuery,
} from './api';
import type { APIKeyRecord } from './types';

const ALL_STATUSES_VALUE = '__all__';

function formatNumber(value: number) {
  return new Intl.NumberFormat().format(value);
}

function formatCurrency(value: number) {
  return new Intl.NumberFormat(undefined, {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: 2,
    maximumFractionDigits: 4,
  }).format(value);
}

function formatTimestamp(value?: string | null) {
  if (!value) {
    return '';
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return value;
  }
  return parsed.toLocaleString();
}

export function APIKeysPage() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { confirm } = useAdminRuntime();
  const toast = useToast();
  const [filters, setFilters] = useState<APIKeyListFilters>({
    status: '',
    q: '',
    sort: 'created_at',
    order: 'desc',
  });
  const [createOpen, setCreateOpen] = useState(false);
  const [createName, setCreateName] = useState('');
  const [createdPlaintext, setCreatedPlaintext] = useState<string | null>(null);
  const [createdKeyName, setCreatedKeyName] = useState<string>('');
  const [renameTarget, setRenameTarget] = useState<APIKeyRecord | null>(null);
  const [renameValue, setRenameValue] = useState('');

  const listQuery = useClientKeysQuery(filters);
  const mutations = useClientKeyMutations();

  const keys = listQuery.data?.keys ?? [];

  const loading = listQuery.isLoading;
  const error = listQuery.error;

  if (loading) {
    return <LoadingState label={t('apiKeys.loadingData')} />;
  }

  if (error) {
    return (
      <ErrorState
        title={t('apiKeys.failedToLoad')}
        description={
          error instanceof Error ? error.message : t('common.unknownError')
        }
        actionLabel={t('common.retry')}
        onAction={() => void listQuery.refetch()}
      />
    );
  }

  const handleCreate = async () => {
    try {
      const response = await mutations.createMutation.mutateAsync(createName);
      setCreateOpen(false);
      setCreateName('');
      setCreatedKeyName(response.key.name);
      setCreatedPlaintext(response.plaintext_key);
      toast.success(t('apiKeys.messages.created', { name: response.key.name }));
    } catch (mutationError) {
      toast.error(
        mutationError instanceof Error
          ? mutationError.message
          : t('apiKeys.messages.createFailed'),
      );
    }
  };

  const handleRename = async () => {
    if (!renameTarget) {
      return;
    }
    try {
      await mutations.updateMutation.mutateAsync({
        id: renameTarget.id,
        payload: { name: renameValue },
      });
      toast.success(t('apiKeys.messages.renamed', { name: renameTarget.name }));
      setRenameTarget(null);
      setRenameValue('');
    } catch (mutationError) {
      toast.error(
        mutationError instanceof Error
          ? mutationError.message
          : t('apiKeys.messages.renameFailed'),
      );
    }
  };

  const handleStatusChange = async (
    record: APIKeyRecord,
    status: 'active' | 'disabled',
  ) => {
    try {
      await mutations.updateMutation.mutateAsync({
        id: record.id,
        payload: { status },
      });
      toast.success(
        status === 'active'
          ? t('apiKeys.messages.enabled', { name: record.name })
          : t('apiKeys.messages.disabled', { name: record.name }),
      );
    } catch (mutationError) {
      toast.error(
        mutationError instanceof Error
          ? mutationError.message
          : t('apiKeys.messages.statusFailed'),
      );
    }
  };

  const handleDelete = async (record: APIKeyRecord) => {
    const confirmed = await confirm({
      title: t('apiKeys.actions.delete'),
      message: t('apiKeys.messages.deleteConfirm', { name: record.name }),
      confirmLabel: t('apiKeys.actions.delete'),
      cancelLabel: t('common.cancel'),
      destructive: true,
    });

    if (!confirmed) {
      return;
    }
    try {
      await mutations.deleteMutation.mutateAsync(record.id);
      toast.success(t('apiKeys.messages.deleted', { name: record.name }));
    } catch (mutationError) {
      toast.error(
        mutationError instanceof Error
          ? mutationError.message
          : t('apiKeys.messages.deleteFailed'),
      );
    }
  };

  return (
    <div className="space-y-6">
      <AdminPageHeader
        title={t('apiKeys.title')}
        description={t('apiKeys.description')}
        actions={
          <div className="flex items-center gap-2">
            <Button variant="outline" onClick={() => void listQuery.refetch()}>
              <RiRefreshLine />
              {t('common.refresh')}
            </Button>
            <Button onClick={() => setCreateOpen(true)}>
              <RiAddLine />
              {t('apiKeys.actions.createKey')}
            </Button>
          </div>
        }
      />

      <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
        <div className="relative w-full lg:max-w-md">
          <RiSearchLine className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            className="pl-9"
            placeholder={t('apiKeys.searchPlaceholder')}
            value={filters.q}
            onChange={(event) =>
              setFilters((current) => ({ ...current, q: event.target.value }))
            }
          />
        </div>
        <div className="flex flex-col gap-3 md:flex-row md:items-center">
          <Select
            value={filters.status || ALL_STATUSES_VALUE}
            onValueChange={(value) => {
              const next =
                typeof value === 'string' ? value : ALL_STATUSES_VALUE;
              setFilters((current) => ({
                ...current,
                status: next === ALL_STATUSES_VALUE ? '' : next,
              }));
            }}
          >
            <SelectTrigger className="w-full md:w-44">
              <SelectValue placeholder={t('apiKeys.filters.status')} />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={ALL_STATUSES_VALUE}>
                {t('apiKeys.status.all')}
              </SelectItem>
              <SelectItem value="active">
                {t('apiKeys.status.active')}
              </SelectItem>
              <SelectItem value="disabled">
                {t('apiKeys.status.disabled')}
              </SelectItem>
              <SelectItem value="deleted">
                {t('apiKeys.status.deleted')}
              </SelectItem>
            </SelectContent>
          </Select>

          <Select
            value={`${filters.sort}:${filters.order}`}
            onValueChange={(value) => {
              if (typeof value !== 'string') {
                return;
              }
              const [sort, order] = value.split(':');
              setFilters((current) => ({
                ...current,
                sort: sort ?? current.sort,
                order: order ?? current.order,
              }));
            }}
          >
            <SelectTrigger className="w-full md:w-52">
              <SelectValue placeholder={t('apiKeys.filters.sort')} />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="created_at:desc">
                {t('apiKeys.sort.newestFirst')}
              </SelectItem>
              <SelectItem value="created_at:asc">
                {t('apiKeys.sort.oldestFirst')}
              </SelectItem>
              <SelectItem value="last_used_at:desc">
                {t('apiKeys.sort.recentlyUsed')}
              </SelectItem>
              <SelectItem value="name:asc">
                {t('apiKeys.sort.nameAZ')}
              </SelectItem>
              <SelectItem value="request_count_30d:desc">
                {t('apiKeys.sort.mostActive')}
              </SelectItem>
            </SelectContent>
          </Select>
        </div>
      </div>

      {keys.length === 0 ? (
        <EmptyState
          title={t('apiKeys.emptyTitle')}
          description={t('apiKeys.emptyDescription')}
        />
      ) : (
        <Panel className="overflow-hidden px-0 py-0">
          <div className="w-full overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow className="hover:bg-transparent">
                  <TableHead>{t('apiKeys.columns.name')}</TableHead>
                  <TableHead>{t('apiKeys.columns.maskedKey')}</TableHead>
                  <TableHead>{t('apiKeys.columns.created')}</TableHead>
                  <TableHead>{t('apiKeys.columns.lastUsed')}</TableHead>
                  <TableHead>{t('apiKeys.columns.status')}</TableHead>
                  <TableHead>{t('apiKeys.columns.usage30d')}</TableHead>
                  <TableHead className="text-right">
                    {t('apiKeys.columns.actions')}
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {keys.map((record) => (
                  <TableRow key={record.id}>
                    <TableCell>
                      <div className="flex items-center gap-2 font-medium">
                        <RiKey2Line className="size-4 shrink-0 text-muted-foreground" />
                        <span className="truncate">{record.name}</span>
                      </div>
                    </TableCell>
                    <TableCell className="font-mono text-xs text-muted-foreground">
                      <span className="block max-w-[18rem] truncate">
                        {record.masked_value}
                      </span>
                    </TableCell>
                    <TableCell className="text-sm text-muted-foreground">
                      {formatTimestamp(record.created_at) || t('apiKeys.never')}
                    </TableCell>
                    <TableCell className="text-sm text-muted-foreground">
                      {formatTimestamp(record.last_used_at) ||
                        t('apiKeys.never')}
                    </TableCell>
                    <TableCell>
                      {record.status === 'active' ? (
                        <Badge className="bg-emerald-500/10 text-emerald-700">
                          {t('apiKeys.status.active')}
                        </Badge>
                      ) : record.status === 'disabled' ? (
                        <Badge className="bg-amber-500/10 text-amber-700">
                          {t('apiKeys.status.disabled')}
                        </Badge>
                      ) : (
                        <Badge variant="secondary">
                          {t('apiKeys.status.deleted')}
                        </Badge>
                      )}
                    </TableCell>
                    <TableCell className="text-sm text-muted-foreground">
                      {record.usage_summary_30d
                        ? t('apiKeys.usageSummary', {
                            requests: formatNumber(
                              record.usage_summary_30d.request_count,
                            ),
                            tokens: formatNumber(
                              record.usage_summary_30d.total_tokens,
                            ),
                            cost: formatCurrency(
                              record.usage_summary_30d.estimated_cost_usd,
                            ),
                          })
                        : t('apiKeys.noTrafficYet')}
                    </TableCell>
                    <TableCell className="text-right">
                      <DropdownMenu>
                        <DropdownMenuTrigger
                          render={
                            <Button variant="ghost" size="icon-sm">
                              <RiMore2Fill />
                            </Button>
                          }
                        />
                        <DropdownMenuContent align="end">
                          <DropdownMenuItem
                            onClick={() =>
                              void navigate({
                                to: '/logs',
                                search: { apiKeyId: record.id },
                              })
                            }
                          >
                            <RiRefreshLine className="mr-2 size-4" />
                            {t('apiKeys.actions.viewUsage')}
                          </DropdownMenuItem>
                          <DropdownMenuItem
                            onClick={() => {
                              setRenameTarget(record);
                              setRenameValue(record.name);
                            }}
                          >
                            <RiEdit2Line className="mr-2 size-4" />
                            {t('apiKeys.actions.rename')}
                          </DropdownMenuItem>
                          {record.status === 'active' ? (
                            <DropdownMenuItem
                              onClick={() =>
                                handleStatusChange(record, 'disabled')
                              }
                            >
                              <RiShutDownLine className="mr-2 size-4" />
                              {t('apiKeys.actions.disable')}
                            </DropdownMenuItem>
                          ) : record.status === 'disabled' ? (
                            <DropdownMenuItem
                              onClick={() =>
                                handleStatusChange(record, 'active')
                              }
                            >
                              <RiRefreshLine className="mr-2 size-4" />
                              {t('apiKeys.actions.enable')}
                            </DropdownMenuItem>
                          ) : null}
                          <DropdownMenuItem
                            className="text-destructive"
                            onClick={() => handleDelete(record)}
                          >
                            <RiDeleteBinLine className="mr-2 size-4" />
                            {t('apiKeys.actions.delete')}
                          </DropdownMenuItem>
                        </DropdownMenuContent>
                      </DropdownMenu>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </Panel>
      )}

      <Dialog open={createOpen} onOpenChange={setCreateOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('apiKeys.dialogs.create.title')}</DialogTitle>
            <DialogDescription>
              {t('apiKeys.dialogs.create.description')}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-2">
            <label className="text-sm font-medium" htmlFor="api-key-name">
              {t('apiKeys.fields.name')}
            </label>
            <Input
              id="api-key-name"
              placeholder={t('apiKeys.fields.namePlaceholder')}
              value={createName}
              onChange={(event) => setCreateName(event.target.value)}
            />
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setCreateOpen(false)}>
              {t('common.cancel')}
            </Button>
            <Button
              onClick={() => void handleCreate()}
              disabled={mutations.createMutation.isPending}
            >
              {t('apiKeys.actions.createKey')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog
        open={Boolean(createdPlaintext)}
        onOpenChange={(open) => {
          if (!open) {
            setCreatedPlaintext(null);
            setCreatedKeyName('');
          }
        }}
      >
        <DialogContent className="max-w-[calc(100vw-2rem)] sm:max-w-2xl">
          <DialogHeader>
            <DialogTitle className="truncate">
              {createdKeyName || t('apiKeys.dialogs.created.title')}
            </DialogTitle>
            <DialogDescription>
              {t('apiKeys.dialogs.created.description')}
            </DialogDescription>
          </DialogHeader>
          <Panel className="space-y-3 border border-border/60 bg-muted/30 p-4">
            <div className="flex min-w-0 flex-col gap-3 overflow-hidden rounded-lg bg-background px-3 py-3 sm:flex-row sm:items-center">
              <span className="block min-w-0 flex-1 whitespace-pre-wrap break-all font-mono text-sm">
                {createdPlaintext}
              </span>
              <CopyButton value={createdPlaintext ?? ''} className="shrink-0">
                {t('apiKeys.actions.copyKey')}
              </CopyButton>
            </div>
            <p className="text-sm text-muted-foreground">
              {t('apiKeys.dialogs.created.helper')}
            </p>
          </Panel>
        </DialogContent>
      </Dialog>

      <Dialog
        open={Boolean(renameTarget)}
        onOpenChange={(open) => {
          if (!open) {
            setRenameTarget(null);
            setRenameValue('');
          }
        }}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{t('apiKeys.dialogs.rename.title')}</DialogTitle>
            <DialogDescription>
              {t('apiKeys.dialogs.rename.description')}
            </DialogDescription>
          </DialogHeader>
          <Input
            value={renameValue}
            onChange={(event) => setRenameValue(event.target.value)}
          />
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => {
                setRenameTarget(null);
                setRenameValue('');
              }}
            >
              {t('common.cancel')}
            </Button>
            <Button
              onClick={() => void handleRename()}
              disabled={mutations.updateMutation.isPending}
            >
              {t('apiKeys.actions.saveName')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
