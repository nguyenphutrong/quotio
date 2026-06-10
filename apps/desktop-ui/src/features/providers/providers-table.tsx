import { Badge } from '@quotio/ui/components/badge';
import { Button } from '@quotio/ui/components/button';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@quotio/ui/components/table';
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from '@quotio/ui/components/tooltip';
import {
  RiAddLine,
  RiArrowDownSLine,
  RiArrowRightSLine,
  RiDeleteBinLine,
  RiFlashlightLine,
  RiPauseCircleLine,
  RiPlayCircleLine,
  RiPlugLine,
  RiRefreshLine,
} from '@remixicon/react';
import React, { useMemo, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { ProviderIcon } from '@/components/admin/provider-icon';
import type { ProviderResponse } from '@/features/providers/types';
import {
  getProviderDisplayName,
  normalizeProviderId,
  providerCatalog,
} from '@/features/providers/types';
import { useAdminRuntime } from '@/lib/admin/runtime';

export function ProvidersTable({
  providers,
  editingProviderId,
  onSelect,
  onTest,
  onRefresh,
  onToggleDisabled,
  onDelete,
  onAddConnection,
  busyId,
}: {
  providers: ProviderResponse[];
  editingProviderId: string | null;
  onSelect: (provider: ProviderResponse) => void;
  onTest: (provider: ProviderResponse) => Promise<void>;
  onRefresh: (provider: ProviderResponse) => Promise<void>;
  onToggleDisabled: (provider: ProviderResponse) => Promise<void>;
  onDelete: (provider: ProviderResponse) => Promise<void>;
  onAddConnection?: (providerKey: string) => void;
  busyId: string | null;
}) {
  const { t } = useTranslation();
  const { confirm } = useAdminRuntime();
  const [collapsedGroups, setCollapsedGroups] = useState<Set<string>>(
    new Set(),
  );

  const toggleGroup = (key: string) => {
    setCollapsedGroups((prev) => {
      const next = new Set(prev);
      if (next.has(key)) {
        next.delete(key);
      } else {
        next.add(key);
      }
      return next;
    });
  };

  const grouped = useMemo(() => {
    const map = new Map<string, ProviderResponse[]>();
    for (const [key] of Object.entries(providerCatalog)) {
      map.set(key, []);
    }
    for (const p of providers) {
      const providerKey = normalizeProviderId(p.provider);
      const list = map.get(providerKey) || [];
      list.push(p);
      map.set(providerKey, list);
    }
    return Array.from(map.entries())
      .map(([key, list]) => ({
        providerKey: key,
        catalog: providerCatalog[key] || {
          name: getProviderDisplayName(key),
          type: list[0]?.validation?.auth_type || 'api_key',
          icon: '🧩',
        },
        connections: list,
      }))
      .filter((g) => g.connections.length > 0)
      .sort((a, b) => {
        if (a.connections.length > 0 && b.connections.length === 0) return -1;
        if (a.connections.length === 0 && b.connections.length > 0) return 1;
        return a.catalog.name.localeCompare(b.catalog.name);
      });
  }, [providers]);

  return (
    <div className="space-y-4">
      <div className="rounded-xl border border-border overflow-hidden">
        <Table>
          <TableHeader>
            <TableRow className="hover:bg-transparent [&>th]:py-2 [&>th]:h-10 text-xs">
              <TableHead className="w-[300px]">
                {t('providers.table.provider')}
              </TableHead>
              <TableHead>{t('providers.table.type')}</TableHead>
              <TableHead>{t('providers.table.connections')}</TableHead>
              <TableHead>{t('providers.table.status')}</TableHead>
              <TableHead className="text-right">
                {t('providers.table.actions')}
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {grouped.length === 0 && (
              <TableRow>
                <TableCell
                  colSpan={5}
                  className="h-24 text-center text-muted-foreground"
                >
                  {t('providers.empty.noProviders')}
                </TableCell>
              </TableRow>
            )}
            {grouped.map((group) => {
              const isExpanded = !collapsedGroups.has(group.providerKey);
              const connectionCount = group.connections.length;

              // Group status logic
              let groupStatus = t('providers.status.noConnections');
              let statusColor = 'text-muted-foreground';
              if (connectionCount > 0) {
                const hasError = group.connections.some(
                  (c) => !c.validation.valid,
                );
                if (hasError) {
                  groupStatus = t('providers.status.error');
                  statusColor =
                    'text-danger bg-danger/10 px-2 py-0.5 rounded-md text-xs font-medium';
                } else {
                  groupStatus = t('providers.status.ready');
                  statusColor =
                    'text-success bg-success/10 px-2 py-0.5 rounded-md text-xs font-medium';
                }
              }

              return (
                <React.Fragment key={group.providerKey}>
                  {/* Group Row */}
                  <TableRow
                    className="group hover:bg-muted/50 data-[state=selected]:bg-muted [&>td]:py-2"
                    onClick={() => toggleGroup(group.providerKey)}
                  >
                    <TableCell className="font-medium">
                      <div className="flex items-center gap-2">
                        <div className="text-muted-foreground w-4 flex justify-center">
                          {isExpanded ? (
                            <RiArrowDownSLine className="h-4 w-4" />
                          ) : (
                            <RiArrowRightSLine className="h-4 w-4" />
                          )}
                        </div>
                        <div className="flex h-6 w-6 items-center justify-center rounded-md border border-border bg-muted">
                          <ProviderIcon
                            provider={group.providerKey}
                            className="h-4 w-4"
                          />
                        </div>
                        <span className="text-sm">{group.catalog.name}</span>
                      </div>
                    </TableCell>
                    <TableCell>
                      <Badge
                        variant="secondary"
                        className="font-normal text-[10px] uppercase tracking-wider py-0 px-1.5"
                      >
                        {group.catalog.type === 'oauth' ? 'OAuth' : 'API Key'}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-sm">{connectionCount}</TableCell>
                    <TableCell>
                      <span className={statusColor}>{groupStatus}</span>
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="flex items-center justify-end gap-2">
                        <Tooltip>
                          <TooltipTrigger
                            render={
                              <Button
                                variant="ghost"
                                size="sm"
                                className="h-7 px-2 text-xs text-muted-foreground hover:text-foreground"
                                onClick={(e) => {
                                  e.stopPropagation();
                                  onAddConnection?.(group.providerKey);
                                }}
                              >
                                <RiAddLine className="mr-1 h-3 w-3" />
                                {t('providers.actions.addConnection')}
                              </Button>
                            }
                          />
                          <TooltipContent>
                            {t('providers.tooltips.addConnection')}
                          </TooltipContent>
                        </Tooltip>
                      </div>
                    </TableCell>
                  </TableRow>

                  {/* Connection Rows */}
                  {isExpanded &&
                    group.connections.map((connection) => {
                      const isSelected = editingProviderId === connection.id;
                      const isValid = connection.validation.valid;
                      const canEdit =
                        !providerCatalog[group.providerKey] ||
                        group.providerKey === 'opencode-go';
                      const checkedAt = connection.validation.checked_at
                        ? new Date(
                            connection.validation.checked_at,
                          ).toLocaleTimeString()
                        : t('providers.status.unknown');

                      return (
                        <TableRow
                          key={connection.id}
                          className={`cursor-default bg-muted/30 hover:bg-muted/60 [&>td]:py-2 ${
                            isSelected ? 'bg-muted/60' : ''
                          } ${connection.disabled ? 'opacity-50' : ''}`}
                          onClick={() => {
                            if (canEdit) {
                              onSelect(connection);
                            }
                          }}
                        >
                          <TableCell className="pl-12">
                            <div className="flex items-center gap-2">
                              <RiPlugLine className="h-3 w-3 text-muted-foreground" />
                              <div className="flex flex-col">
                                <span className="text-sm font-medium">
                                  {connection.validation.account_identity ||
                                    connection.label ||
                                    connection.id}
                                </span>
                                {connection.validation.error && (
                                  <span className="text-xs text-danger line-clamp-1">
                                    {connection.validation.error}
                                  </span>
                                )}
                              </div>
                            </div>
                          </TableCell>
                          <TableCell></TableCell>
                          <TableCell></TableCell>
                          <TableCell>
                            <div className="flex flex-col justify-center">
                              <div className="flex items-center gap-1.5">
                                <div
                                  className={`h-1.5 w-1.5 rounded-full ${
                                    isValid ? 'bg-success' : 'bg-danger'
                                  }`}
                                />
                                <span className="text-xs font-medium text-foreground">
                                  {isValid
                                    ? t('providers.status.active')
                                    : t('providers.status.error')}
                                </span>
                              </div>
                              {connection.validation.checked_at && (
                                <span
                                  className="text-[10px] text-muted-foreground pl-3"
                                  title={new Date(
                                    connection.validation.checked_at,
                                  ).toLocaleString()}
                                >
                                  {t('providers.table.testedAt', {
                                    time: checkedAt,
                                  })}
                                </span>
                              )}
                            </div>
                          </TableCell>
                          <TableCell className="text-right">
                            <div className="flex items-center justify-end gap-1">
                              <Tooltip>
                                <TooltipTrigger
                                  render={
                                    <Button
                                      variant="ghost"
                                      size="sm"
                                      className="h-7 px-2 text-xs"
                                      onClick={(e) => {
                                        e.stopPropagation();
                                        onTest(connection);
                                      }}
                                      disabled={busyId === connection.id}
                                    >
                                      <RiFlashlightLine className="mr-1 h-3 w-3" />
                                      {t('providers.actions.test')}
                                    </Button>
                                  }
                                />
                                <TooltipContent>
                                  {t('providers.tooltips.testConnection')}
                                </TooltipContent>
                              </Tooltip>

                              {connection.validation.auth_type === 'oauth' && (
                                <Tooltip>
                                  <TooltipTrigger
                                    render={
                                      <Button
                                        variant="ghost"
                                        size="icon"
                                        className="h-7 w-7"
                                        onClick={(e) => {
                                          e.stopPropagation();
                                          onRefresh(connection);
                                        }}
                                        disabled={busyId === connection.id}
                                      >
                                        <RiRefreshLine className="h-3 w-3" />
                                      </Button>
                                    }
                                  />
                                  <TooltipContent>
                                    {t('providers.tooltips.refreshToken')}
                                  </TooltipContent>
                                </Tooltip>
                              )}

                              <Tooltip>
                                <TooltipTrigger
                                  render={
                                    <Button
                                      variant="ghost"
                                      size="icon"
                                      className={`h-7 w-7 ${
                                        connection.disabled
                                          ? 'text-success hover:text-success'
                                          : 'text-warning hover:text-warning'
                                      }`}
                                      onClick={(e) => {
                                        e.stopPropagation();
                                        onToggleDisabled(connection);
                                      }}
                                      disabled={busyId === connection.id}
                                    >
                                      {connection.disabled ? (
                                        <RiPlayCircleLine className="h-3 w-3" />
                                      ) : (
                                        <RiPauseCircleLine className="h-3 w-3" />
                                      )}
                                    </Button>
                                  }
                                />
                                <TooltipContent>
                                  {connection.disabled
                                    ? t('providers.tooltips.enableConnection')
                                    : t('providers.tooltips.disableConnection')}
                                </TooltipContent>
                              </Tooltip>

                              <Tooltip>
                                <TooltipTrigger
                                  render={
                                    <Button
                                      variant="ghost"
                                      size="icon"
                                      className="h-7 w-7 text-danger hover:text-danger hover:bg-danger/10"
                                      onClick={async (e) => {
                                        e.stopPropagation();
                                        const name =
                                          connection.label || connection.id;
                                        const accepted = await confirm({
                                          title: t(
                                            'providers.dialogs.deleteTitle',
                                          ),
                                          message: t(
                                            'providers.dialogs.deleteMessage',
                                            { name },
                                          ),
                                          confirmLabel: t(
                                            'providers.actions.delete',
                                          ),
                                          cancelLabel: t('common.cancel'),
                                          destructive: true,
                                        });

                                        if (accepted) {
                                          await onDelete(connection);
                                        }
                                      }}
                                      disabled={busyId === connection.id}
                                    >
                                      <RiDeleteBinLine className="h-3 w-3" />
                                    </Button>
                                  }
                                />
                                <TooltipContent>
                                  {t('providers.tooltips.deleteConnection')}
                                </TooltipContent>
                              </Tooltip>
                            </div>
                          </TableCell>
                        </TableRow>
                      );
                    })}
                </React.Fragment>
              );
            })}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}
