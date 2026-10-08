# Account quota timeline

## Summary

Add a Battery-style history of account quota to the macOS Quota screen. Users select one account and one quota metric to see how its remaining level changed, where observations are missing, and when a reset or recovery may have occurred.

This plan targets the current SwiftUI macOS app and its Rust host. It does not implement a separate GPUI interface, an iPhone history screen, or a standalone CLI history command.

## Visual references

The user supplied a quota card reference on 2026-10-05 with narrow vertical blue bars, a percentage axis, provider/account identity, reset information, and summary values below the chart. Reuse that hierarchy, not its literal monthly cycle or its inconsistent combination of a descending level chart and a "Current usage" label.

Use macOS-native typography, controls, and semantic backgrounds. The distinctive element is the narrow-column quota level chart. Keep text and chart marks on a stable, legible background rather than adding glass blur.

## Alternatives considered

| Direction | Decision |
| --- | --- |
| Battery-style quota level history | Include. Directly answers how much quota remained at a given time. |
| Per-period consumption bars | Exclude from this feature. Differences between quota observations are not reliable token, request, or cost accounting. |
| Account comparison dashboard | Exclude. Different plans and overlapping windows make an aggregate percentage misleading. |
| Exhaustion forecast and new alerts | Exclude. Sparse observations, rolling recovery, and provider changes need a separate prediction design. |

## Behavior

### Navigation and metric selection

1. Each account card on the macOS Quota screen has a "Quota history" action. It opens a native detail sheet containing the account identity, metric picker, range picker, chart, and summary. Existing account actions and quota cards retain their behavior. Do not add a chart to every collapsed card or a new top-level sidebar destination.
2. The detail starts with the first available percentage metric in the account's existing presentation order. The picker includes current metrics and metrics that have retained historical observations. Historical-only metrics are labeled as no longer reported. If no percentage metric exists, show the reason instead of selecting an unrelated balance.
3. Session, Weekly, Claude Session, Claude Weekly, Spark Session, and Spark Weekly are independent histories when supplied by the provider. Missing metrics produce no empty slots. Do not synthesize metrics, average their percentages, or add Session consumption to Weekly consumption.
4. The range picker offers 24 hours, 7 days, and 30 days, defaulting to 24 hours. Ranges end at the current time. Changing a range or metric does not refresh the provider or change account selection elsewhere in the app.
5. The chart follows the existing quota display preference. Remaining mode uses a 0% to 100% axis and the label "Quota remaining". Used mode displays the complementary percentage and the label "Quota used". This feature introduces no second display-mode setting. Examples and design previews use remaining mode.

### Observations and chart semantics

6. History starts when this feature begins recording. Do not backfill past days from today's value, import unrelated Codex token analytics, or imply that earlier quota observations exist.
7. Every plotted value comes from a successful provider observation. Reading a cache, reopening the window, reading a snapshot, or retrying a failed fetch must not create a new value at a later time. Repeated delivery of one observation appears once.
8. Record tracked accounts while the host runs, regardless of whether the main window or history sheet is open. Existing refresh preferences still control fetching. Enabling history must not increase provider request frequency, prevent sleep, or install a new background daemon.
9. Render narrow vertical bars on a true time axis. A time bin uses its latest observed quota level, not a sum or arithmetic average. Selecting it reveals the latest value, its actual observation time, the observed minimum and maximum within that bin, reset information, and source confidence. Multiple events in one bin remain distinguishable in the detail.
10. Empty time bins remain empty. Do not carry a value through a sleep, shutdown, offline period, or failed refresh as if it were measured. Do not connect a continuous line across missing bins. The sheet explains that history is collected only while the host runs and can fetch quota.
11. A real 0% remaining value is visible and selectable at the baseline. It is not the same state as a missing observation. A real 100% value reaches the top of the scale.
12. Unknown, disabled, unlimited, and amount-only metrics are not converted to 0% or 100%. Their observed state changes are available in the selection detail and break any implied numeric continuity. A balance without a known limit gets an explanation rather than a percentage graph.
13. Provider-supplied estimated quota stays labeled as estimated. Never describe provider confidence as exact if the source does not support it. Chart color alone must not carry this distinction.
14. Show a scheduled reset from provider information as "Expected reset". Do not generate a reset marker merely because that time has elapsed. A reset inferred from observations is shown as "Reset inferred between [time] and [time]", never as an exact measured instant.
15. Infer a reset interval only when the previous provider reset timestamp lies between two adjacent usable observations, the next reset advances, the quota level increases, and the account, metric, and quota basis remain compatible. A level increase without that evidence is "Quota increased". Rolling recovery, manual resets, and corrections must not be mislabeled as scheduled resets. If no exact reset timestamp exists, retain the provider's description without inventing one.
16. A plan, limit, unit, source identity, or quota interpretation change creates a visible boundary. Values on either side are historical facts but not a continuous comparable consumption series. Do not calculate consumption or a reset across that boundary.

### Summaries and interaction

17. Below the chart show the latest observed quota level with its update time, the provider's next reset if known, and the lowest observed remaining level within the selected range. Label the last value "Lowest observed". In used mode the equivalent statistic is "Highest observed used". Do not call it a complete-range minimum when observations are missing.
18. The headline percentage matches the latest observation, not an average of the bars. If it is stale, show its age and stale status. Do not show daily consumption, percentage growth versus last week, or an exhaustion prediction in this feature.
19. Hovering or clicking a bar shows its detail. Keyboard focus can move through observed bins with arrow keys. The selected bin has a visible indicator. VoiceOver can read its time, value, confidence, and events without requiring hover. Escape dismisses the sheet and returns focus to its opener.
20. Support light and dark appearance, increased contrast, reduced motion, existing sensitive-information masking, and narrow window sizes. Long provider/account/metric labels do not cover the chart or its controls. Status colors reuse the existing quota policy and remain accompanied by text.

### Loading, failures, and lifecycle

21. Distinguish loading, recording started with no observations, no observations in the selected range, unsupported percentage metric, history disabled, unavailable host capability, and history read/write failure. Empty history must not be presented as an exhausted account.
22. A history read failure offers Retry without forcing a provider fetch. A storage failure must not break current quota refreshes or erase previously readable history. Show that recent history could not be saved rather than silently implying complete recording.
23. While the sheet is open, new committed observations become visible through the existing host refresh lifecycle. A failed range/metric request cannot replace a newer successful selection. Dismissing the sheet or changing hosts cancels its pending reads; one host's history never appears under another host.
24. A disconnected host cannot load additional history. Data already displayed can remain visible with an offline label and its timestamp, but the UI must not imply that recording continues. An older host without the capability shows "Quota history is not supported by this host" rather than a generic empty chart.

### Retention, identity, and privacy

25. Keep a rolling 30 days of observations on the owning host. Reopening the app or restarting the host preserves retained history when identity continuity is confirmed. Unverified borrowed sources without a durable identity start a separate epoch on restart under rule 28; older retained observations are not exposed through the new identity. There is no cloud sync or retrospective collection while the host is stopped. Standalone `quotio usage` runs do not contribute history in this scope.
26. History recording is enabled by default for tracked accounts. An owner can pause/resume it in Quota settings. Pausing keeps existing retained history readable and still ages it out after 30 days. Resuming starts with the next observation, without filling the pause interval.
27. An owner can clear one account's history or all host history, with confirmation. Clearing history does not remove credentials, accounts, refresh preferences, or the current quota snapshot. The next new provider observation starts a new history. An already in-flight fetch from before the clear must not restore deleted history.
28. Changing an account alias preserves history. A resolver-confirmed account redirect can preserve the same verified identity's history. Same-email accounts in different tenants remain separate. Replacing credentials or switching to an unverified different identity cannot expose the previous identity's history. When identity continuity cannot be established, start a separate history rather than guessing.
29. Explicit account removal clears its history. Temporary loss of a borrowed source, logout, or fetch failure does not by itself fabricate new observations or delete retained history. Removed accounts cannot be retrieved through stale account IDs. Late fetch completion cannot recreate removed history.
30. Store quota values, opaque account/metric identifiers, timestamps, quota basis, and provenance only. Do not store credentials, email addresses, file paths, raw provider payloads, or prompt content in history. History endpoints are owner-only in this scope; do not extend history access to anonymous or paired read-only clients.
31. Hosts running with `--no-saved-accounts` do not provide persistent history in this scope, because their host identity is session-scoped. Advertise the unavailable capability explicitly. This does not change their existing snapshot behavior.
