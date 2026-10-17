//! Accounts page, built from the Wonder artboard "Page - Quotio Accounts".
use gpui_kit::assets::IconName;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement, IntoElement, ParentElement, SharedString,
    StatefulInteractiveElement, Styled, div, prelude::FluentBuilder as _, px,
};

use super::SettingsWindow;
use crate::model::{AccountView, MetricView, Overview, ProviderGroup};
use crate::theme::{Palette, palette};
use crate::ui::{icon, progress, provider_logo, value_color};

impl SettingsWindow {
    pub(super) fn accounts_page(
        &self,
        overview: Option<&Overview>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = palette(cx).clone();
        let store = self.store.read(cx);
        let subtitle: SharedString = match (overview, &store.error) {
            (_, Some(error)) => format!("Host unavailable: {error}").into(),
            (Some(overview), None) => overview.status_line().into(),
            (None, None) => "Loading…".into(),
        };
        let refreshing = store.refreshing;
        let header = div()
            .flex()
            .items_start()
            .gap(px(16.))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .gap(px(4.))
                    .text_size(px(14.))
                    .font_weight(FontWeight::MEDIUM)
                    .child(div().text_color(p.text_strong).child("Accounts"))
                    .child(div().text_color(p.text_soft).child(subtitle)),
            )
            .child(
                div()
                    .w(px(200.))
                    .h(px(32.))
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .px(px(10.))
                    .rounded(px(10.))
                    .bg(p.bg_weak)
                    .text_size(px(14.))
                    .text_color(p.text_soft)
                    .child(icon(IconName::Search, 16., p.text_soft))
                    .child("Search accounts"),
            )
            .child(
                div()
                    .id("refresh")
                    .h(px(32.))
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .px(px(10.))
                    .rounded(px(10.))
                    .bg(p.bg_white)
                    .shadow(p.button())
                    .cursor_pointer()
                    .when(refreshing, |s| s.opacity(0.5))
                    .text_size(px(14.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.text_sub)
                    .child(icon(IconName::RefreshCw, 16., p.text_sub))
                    .child("Refresh")
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.store.update(cx, |store, cx| store.refresh(None, cx));
                    })),
            )
            .child(
                div()
                    .h(px(32.))
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .px(px(10.))
                    .rounded(px(10.))
                    .bg(p.text_strong)
                    .text_size(px(14.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.on_strong)
                    .child(icon(IconName::Plus, 16., p.on_strong))
                    .child("Add account"),
            );
        let attention: Vec<AnyElement> = overview
            .into_iter()
            .flat_map(|o| o.attention())
            .map(|(_, account, issue)| {
                div()
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .px(px(12.))
                    .py(px(10.))
                    .rounded(px(12.))
                    .bg(p.bg_white)
                    .shadow(p.raised())
                    .child(
                        div()
                            .size(px(32.))
                            .flex_none()
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(8.))
                            .bg(p.error_alpha)
                            .child(icon(IconName::CircleAlert, 16., p.error)),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .flex_1()
                            .gap(px(2.))
                            .child(
                                div()
                                    .text_size(px(14.))
                                    .font_weight(FontWeight::MEDIUM)
                                    .text_color(p.text_strong)
                                    .child(format!("{} · {}", issue.title, account.name)),
                            )
                            .child(
                                div()
                                    .text_size(px(12.))
                                    .text_color(p.text_sub)
                                    .child(issue.detail.clone()),
                            ),
                    )
                    .child(
                        div()
                            .h(px(32.))
                            .flex_none()
                            .flex()
                            .items_center()
                            .px(px(12.))
                            .rounded(px(10.))
                            .bg(p.text_strong)
                            .text_size(px(14.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(p.on_strong)
                            .child(issue.action.clone()),
                    )
                    .into_any_element()
            })
            .collect();
        let attention_count = attention.len();
        div()
            .flex()
            .flex_col()
            .gap(px(24.))
            .child(header)
            .when(attention_count > 0, |s| {
                s.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(4.))
                        .p(px(4.))
                        .rounded(px(16.))
                        .bg(p.bg_weak)
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap(px(8.))
                                .pt(px(8.))
                                .pb(px(4.))
                                .px(px(12.))
                                .text_size(px(12.))
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(p.text_sub)
                                .child(icon(IconName::TriangleAlert, 16., p.away))
                                .child(match attention_count {
                                    1 => "1 thing needs your attention".to_owned(),
                                    n => format!("{n} things need your attention"),
                                }),
                        )
                        .children(attention),
                )
            })
            .child(
                div().flex().flex_col().gap(px(20.)).children(
                    overview
                        .into_iter()
                        .flat_map(|o| &o.groups)
                        .map(|group| provider_group(group, &p)),
                ),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .px(px(16.))
                    .py(px(12.))
                    .rounded(px(16.))
                    .border_1()
                    .border_dashed()
                    .border_color(p.stroke_soft)
                    .child(icon(IconName::CirclePlus, 18., p.text_soft))
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .flex_1()
                            .gap(px(2.))
                            .child(
                                div()
                                    .text_size(px(14.))
                                    .font_weight(FontWeight::MEDIUM)
                                    .text_color(p.text_sub)
                                    .child("Connect another provider"),
                            )
                            .child(
                                div()
                                    .text_size(px(12.))
                                    .text_color(p.text_soft)
                                    .child("Cursor, Copilot, Kiro, Warp and 39 more"),
                            ),
                    )
                    .child(icon(IconName::ChevronRight, 18., p.text_soft)),
            )
            .into_any_element()
    }
}

fn provider_group(group: &ProviderGroup, p: &Palette) -> AnyElement {
    let count = group.accounts.len();
    div()
        .flex()
        .flex_col()
        .gap(px(8.))
        .child(
            div()
                .flex()
                .items_center()
                .gap(px(8.))
                .px(px(4.))
                .child(provider_logo(&group.provider_id, 18., None, p))
                .child(
                    div()
                        .text_size(px(14.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_strong)
                        .child(group.name.clone()),
                )
                .child(
                    div()
                        .text_size(px(12.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_soft)
                        .child(count.to_string()),
                ),
        )
        .child(
            div()
                .flex()
                .flex_col()
                .rounded(px(16.))
                .border_1()
                .border_color(p.stroke_soft)
                .overflow_hidden()
                .children(
                    group
                        .accounts
                        .iter()
                        .enumerate()
                        .map(|(i, account)| account_row(account, i + 1 < count, p)),
                ),
        )
        .into_any_element()
}

fn account_row(account: &AccountView, divider: bool, p: &Palette) -> AnyElement {
    let identity = div()
        .w(px(220.))
        .flex_none()
        .flex()
        .flex_col()
        .gap(px(2.))
        .child(
            div()
                .flex()
                .items_center()
                .gap(px(6.))
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(px(14.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_strong)
                        .child(account.name.clone()),
                )
                .when(account.pinned, |s| {
                    s.child(icon(IconName::Pin, 14., p.text_soft))
                }),
        )
        .when_some(account.plan.clone(), |s, plan| {
            s.child(
                div()
                    .text_size(px(12.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.text_sub)
                    .child(plan),
            )
        });
    let body = match &account.issue {
        Some(issue) => div()
            .flex_1()
            .flex()
            .items_center()
            .gap(px(8.))
            .px(px(12.))
            .py(px(8.))
            .rounded(px(10.))
            .bg(p.error_alpha)
            .text_size(px(12.))
            .child(icon(IconName::CircleAlert, 16., p.error))
            .child(
                div()
                    .flex_1()
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.text_strong)
                    .child(format!("{}. {}", issue.title, issue.detail)),
            )
            .child(
                div()
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(p.error)
                    .child(issue.action.clone()),
            ),
        None => div()
            .flex_1()
            .grid()
            .grid_cols(2)
            .gap(px(24.))
            .children(account.metrics.iter().map(|m| metric_column(m, p))),
    };
    let action = |glyph: IconName, filled: bool| {
        div()
            .size(px(28.))
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(8.))
            .when(filled, |s| s.bg(p.bg_weak))
            .child(icon(glyph, 16., p.text_sub))
    };
    div()
        .flex()
        .items_center()
        .gap(px(24.))
        .px(px(16.))
        .py(px(14.))
        .when(divider, |s| s.border_b_1().border_color(p.stroke_soft))
        .child(identity)
        .child(body)
        .child(
            div()
                .flex_none()
                .flex()
                .items_center()
                .gap(px(4.))
                .child(action(IconName::ChartLine, true))
                .child(action(IconName::Ellipsis, false)),
        )
        .into_any_element()
}

fn metric_column(metric: &MetricView, p: &Palette) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .gap(px(6.))
        .min_w_0()
        .child(
            div()
                .flex()
                .items_baseline()
                .gap(px(8.))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .text_size(px(12.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_sub)
                        .child(metric.label.clone()),
                )
                .child(
                    div()
                        .text_size(px(14.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(value_color(metric.tone, p))
                        .child(metric.value.clone()),
                ),
        )
        .child(progress(metric.remaining, metric.tone, px(6.), p))
        .when_some(metric.reset_sentence(), |s, reset| {
            s.child(
                div()
                    .text_size(px(12.))
                    .text_color(p.text_soft)
                    .child(reset),
            )
        })
}
