//! iPhone Sharing page, from the Wonder artboard "Page - Quotio iPhone Sharing":
//! connections the iPhone app reads quota through, pairing by QR code, and the
//! devices that hold read-only access.
use std::sync::Arc;

use gpui_kit::assets::IconName;
use gpui_kit::component::WindowExt as _;
use gpui_kit::component::input::InputState;
use gpui_kit::component::notification::Notification;
use gpui_kit::{
    AnyElement, App, AppContext as _, ClipboardItem, Context, Entity, EventEmitter, FontWeight,
    Image, ImageFormat, InteractiveElement, IntoElement, ParentElement, Render, SharedString,
    StatefulInteractiveElement as _, Styled, Window, div, img, prelude::FluentBuilder as _, px,
    white,
};
use serde_json::{Value, json};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use super::SettingsWindow;
use super::widgets::{page_with, rows, section, toggle};
use crate::host::Method;
use crate::prefs;
use crate::sharing::{self, Mode};
use crate::store::QuotaStore;
use crate::theme::{Palette, palette};
use crate::ui::{ButtonKind, button, dialog_footer, field, icon, note, text_field};

impl SettingsWindow {
    /// Read the open connections and the paired devices.
    pub(super) fn load_sharing(&mut self, cx: &mut Context<Self>) {
        let host = self.store.read(cx).host();
        cx.spawn(async move |this, cx| {
            let view = host.call(Method::GET, "/v2/sharing".into(), None).await;
            let clients = host.call(Method::GET, "/v2/clients".into(), None).await;
            let _ = this.update(cx, |this, cx| {
                this.sharing = view.ok();
                this.devices = clients.ok().and_then(|c| c["clients"].as_array().cloned());
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn iphone_page(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let p = palette(cx).clone();
        let computer = if cfg!(windows) {
            "this PC"
        } else {
            "this computer"
        };
        let view = self.sharing.clone().unwrap_or(Value::Null);
        let open: Vec<Mode> = Mode::ALL
            .into_iter()
            .filter(|m| sharing::endpoint(&view, *m).is_some())
            .collect();

        let pair = button("pair", "Pair iPhone", ButtonKind::Primary, &p).map(|s| {
            if open.is_empty() {
                s.opacity(0.5)
            } else {
                s.on_click(cx.listener(|this, _, window, cx| this.pair(window, cx)))
            }
        });

        let help = |mode: Mode| match mode {
            Mode::LocalNetwork => format!("iPhone on the same Wi-Fi as {computer}."),
            Mode::Tailscale => "Check quota away from home over your tailnet.".to_owned(),
            Mode::Proxy => "Your own HTTPS reverse proxy forwards to Quotio.".to_owned(),
        };
        let mut cards: Vec<AnyElement> = [Mode::LocalNetwork, Mode::Tailscale]
            .into_iter()
            .map(|mode| self.connection_card(mode, help(mode), &view, &p, cx))
            .collect();
        cards.push(
            div()
                .id("advanced")
                .flex()
                .items_center()
                .gap(px(6.))
                .cursor_pointer()
                .text_size(px(13.))
                .font_weight(FontWeight::MEDIUM)
                .text_color(p.text_sub)
                .child(icon(
                    if self.sharing_advanced {
                        IconName::ChevronDown
                    } else {
                        IconName::ChevronRight
                    },
                    14.,
                    p.text_sub,
                ))
                .child("Advanced · custom HTTPS proxy, port")
                .on_click(cx.listener(|this, _, _, cx| {
                    this.sharing_advanced = !this.sharing_advanced;
                    cx.notify();
                }))
                .into_any_element(),
        );
        if self.sharing_advanced {
            cards.push(self.advanced(&view, &p, cx));
        }

        let devices = match &self.devices {
            None => note("Paired devices appear here.", p.text_soft)
                .py(px(12.))
                .into_any_element(),
            Some(list) if list.is_empty() => {
                note("No devices yet. Pair an iPhone to start.", p.text_soft)
                    .text_size(px(14.))
                    .py(px(12.))
                    .into_any_element()
            }
            Some(list) => {
                rows(list.iter().map(|d| self.device_row(d, &p, cx)), &p).into_any_element()
            }
        };

        page_with(
            "iPhone Sharing",
            &format!(
                "See quota on your iPhone and in widgets. Read-only — sign-ins stay on {computer}."
            ),
            pair,
            &p,
        )
        .child(section(
            "Connection",
            "Turn on one or both. You pick which one each iPhone uses when pairing.",
            div().flex().flex_col().gap(px(12.)).children(cards),
            &p,
        ))
        .child(section(
            "Paired devices",
            "Each device can only read quota. Access lasts 30 days, or until you revoke it.",
            div().flex().flex_col().child(devices).child(
                note(
                    format!("Keep Quotio running and {computer} awake so your iPhone can refresh."),
                    p.text_soft,
                )
                .pt(px(8.)),
            ),
            &p,
        ))
        .into_any_element()
    }

    fn connection_card(
        &self,
        mode: Mode,
        help: String,
        view: &Value,
        p: &Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let endpoint = sharing::endpoint(view, mode);
        let busy = self.sharing_busy == Some(mode);
        let glyph = match mode {
            Mode::LocalNetwork => IconName::Network,
            Mode::Tailscale => IconName::Globe,
            Mode::Proxy => IconName::Shield,
        };
        let id = SharedString::from(format!("share-{mode:?}"));
        div()
            .flex()
            .flex_col()
            .gap(px(12.))
            .p(px(14.))
            .rounded(px(14.))
            .border_1()
            .border_color(p.stroke_soft)
            .when(busy, |s| s.opacity(0.6))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .child(icon_tile(glyph, p))
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
                                    .child(mode.label()),
                            )
                            .child(div().text_size(px(12.)).text_color(p.text_sub).child(help)),
                    )
                    .child(toggle(
                        id,
                        endpoint.is_some(),
                        self.sharing.is_some() && !busy,
                        p,
                        cx.listener(move |this, on: &bool, window, cx| {
                            this.set_sharing(mode, *on, window, cx)
                        }),
                    )),
            )
            .when_some(endpoint, |s, endpoint| {
                s.child(address_row(mode, endpoint, view, p))
            })
            .into_any_element()
    }

    /// Port for the network listeners and the HTTPS proxy connection.
    fn advanced(&self, view: &Value, p: &Palette, cx: &mut Context<Self>) -> AnyElement {
        div()
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(field(
                "Port",
                text_field(&self.share_port, p).w(px(120.)),
                p,
            ))
            .child(field("Proxy address", text_field(&self.share_proxy, p), p))
            .child(self.connection_card(
                Mode::Proxy,
                "Your own HTTPS reverse proxy forwards to Quotio on this port.".into(),
                view,
                p,
                cx,
            ))
            .child(note(
                "Change the port while every connection is off.",
                p.text_soft,
            ))
            .into_any_element()
    }

    fn set_sharing(&mut self, mode: Mode, on: bool, window: &mut Window, cx: &mut Context<Self>) {
        let mut saved = prefs::get(cx).sharing.clone();
        if on {
            match self.share_port.read(cx).value().trim().parse::<u16>() {
                Ok(port) if port > 0 => saved.port = port,
                _ => {
                    window.push_notification(
                        Notification::error("Enter a port between 1 and 65535."),
                        cx,
                    );
                    return;
                }
            }
            let url = self.share_proxy.read(cx).value().trim().to_owned();
            saved.proxy_url = (!url.is_empty()).then_some(url);
        }
        self.sharing_busy = Some(mode);
        cx.notify();
        let host = self.store.read(cx).host();
        let work = sharing::set(host, mode, on, saved.clone());
        cx.spawn_in(window, async move |this, cx| {
            let result = work.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.sharing_busy = None;
                match result {
                    Ok(_) => prefs::update(cx, |prefs| {
                        prefs.sharing.port = saved.port;
                        prefs.sharing.proxy_url = saved.proxy_url.clone();
                        prefs.sharing.enabled.retain(|m| *m != mode);
                        if on {
                            prefs.sharing.enabled.push(mode);
                        }
                    }),
                    Err(error) => {
                        let verb = if on { "turn on" } else { "turn off" };
                        window.push_notification(
                            Notification::error(format!(
                                "Couldn’t {verb} {}: {error:#}.",
                                mode.label().to_lowercase()
                            )),
                            cx,
                        );
                    }
                }
                this.load_sharing(cx);
            });
        })
        .detach();
    }

    fn device_row(&self, device: &Value, p: &Palette, cx: &mut Context<Self>) -> AnyElement {
        let id = device["id"].as_str().unwrap_or_default().to_owned();
        let label = device["label"].as_str().unwrap_or("Device").to_owned();
        let meta = device["expires_at"]
            .as_str()
            .and_then(|at| OffsetDateTime::parse(at, &Rfc3339).ok())
            .map_or_else(String::new, expiry);
        div()
            .flex()
            .items_center()
            .gap(px(12.))
            .py(px(12.))
            .child(icon_tile(IconName::Smartphone, p))
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
                            .child(label.clone()),
                    )
                    .child(div().text_size(px(12.)).text_color(p.text_sub).child(meta)),
            )
            .child(
                button(
                    SharedString::from(format!("revoke-{id}")),
                    "Revoke",
                    ButtonKind::Secondary,
                    p,
                )
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.confirm_revoke(id.clone(), label.clone(), window, cx)
                })),
            )
            .into_any_element()
    }

    fn confirm_revoke(
        &mut self,
        id: String,
        label: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let this = cx.entity().downgrade();
        window.open_dialog(cx, move |dialog, _, cx| {
            let p = palette(cx).clone();
            let (this, id) = (this.clone(), id.clone());
            dialog
                .w(px(420.))
                .title(format!("Revoke {label}?"))
                .child(
                    note(
                        "It stops reading quota right away. Pair it again to bring it back.",
                        p.text_sub,
                    )
                    .text_size(px(14.)),
                )
                .footer(
                    dialog_footer()
                        .child(
                            button("cancel", "Cancel", ButtonKind::Secondary, &p)
                                .on_click(|_, window, cx| window.close_dialog(cx)),
                        )
                        .child(button("revoke", "Revoke", ButtonKind::Danger, &p).on_click(
                            move |_, window, cx| {
                                window.close_dialog(cx);
                                let id = id.clone();
                                let _ = this.update(cx, |this, cx| this.revoke(id, window, cx));
                            },
                        )),
                )
        });
    }

    fn revoke(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        let work =
            self.store
                .read(cx)
                .host()
                .call(Method::DELETE, format!("/v2/clients/{id}"), None);
        cx.spawn_in(window, async move |this, cx| {
            let result = work.await;
            let _ = this.update_in(cx, |this, window, cx| {
                if let Err(error) = result {
                    window.push_notification(
                        Notification::error(format!("Couldn’t revoke the device: {error:#}.")),
                        cx,
                    );
                }
                this.load_sharing(cx);
            });
        })
        .detach();
    }

    fn pair(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let view = self.sharing.clone().unwrap_or(Value::Null);
        let endpoints: Vec<(Mode, Value)> = Mode::ALL
            .into_iter()
            .filter_map(|m| sharing::endpoint(&view, m).map(|e| (m, e.clone())))
            .collect();
        if endpoints.is_empty() {
            return;
        }
        let store = self.store.clone();
        let flow = cx.new(|cx| PairFlow::new(store, endpoints, window, cx));
        self.dialog_events = Some(
            cx.subscribe_in(&flow, window, |this, _, _: &Paired, _, cx| {
                this.load_sharing(cx)
            }),
        );
        window.open_dialog(cx, move |dialog, _, _| {
            dialog.w(px(440.)).child(flow.clone())
        });
    }
}

/// `https://192.168.1.24:6768 · eth0` with a copy button.
fn address_row(mode: Mode, endpoint: &Value, view: &Value, p: &Palette) -> impl IntoElement {
    let url = endpoint["public_url"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    let listen_ip = endpoint["listen"]
        .as_str()
        .and_then(|l| l.rsplit_once(':'))
        .map(|(ip, _)| ip.to_owned());
    let interface = view["addresses"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|a| a["address"].as_str() == listen_ip.as_deref())
        .and_then(|a| a["interface"].as_str())
        .map(str::to_owned)
        .filter(|_| mode != Mode::Proxy);
    let copy = url.clone();
    div()
        .flex()
        .items_center()
        .gap(px(10.))
        .px(px(12.))
        .py(px(8.))
        .rounded(px(10.))
        .bg(p.bg_weak)
        .text_size(px(13.))
        .child(div().text_color(p.text_soft).child("Address"))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .font_weight(FontWeight::MEDIUM)
                .text_color(p.text_strong)
                .child(url),
        )
        .when_some(interface, |s, name| {
            s.child(div().text_color(p.text_soft).child(name))
        })
        .child(
            div()
                .id(SharedString::from(format!("copy-{mode:?}")))
                .size(px(24.))
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(6.))
                .cursor_pointer()
                .hover(|s| s.bg(p.stroke_soft))
                .child(icon(IconName::Copy, 14., p.text_sub))
                .on_click(move |_, window, cx| {
                    cx.write_to_clipboard(ClipboardItem::new_string(copy.clone()));
                    window.push_notification(Notification::info("Address copied."), cx);
                }),
        )
}

fn icon_tile(glyph: IconName, p: &Palette) -> impl IntoElement {
    div()
        .size(px(32.))
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .rounded(px(10.))
        .bg(p.bg_weak)
        .child(icon(glyph, 16., p.text_sub))
}

/// `Expires Nov 9`, or a nudge to pair again when access is about to end.
fn expiry(at: OffsetDateTime) -> String {
    let days = (at - OffsetDateTime::now_utc()).whole_days();
    if at <= OffsetDateTime::now_utc() {
        "Expired · pair again to restore access".into()
    } else if days < 7 {
        let when = match days {
            0 => "today".to_owned(),
            1 => "in 1 day".to_owned(),
            n => format!("in {n} days"),
        };
        format!("Expires {when} · pair again to extend")
    } else {
        format!("Expires {} {}", &at.month().to_string()[..3], at.day())
    }
}

/// Emitted after a code was shown, so the page lists the new device.
pub struct Paired;

/// The pairing dialog: name the device, choose a connection, then show the QR.
pub struct PairFlow {
    store: Entity<QuotaStore>,
    endpoints: Vec<(Mode, Value)>,
    selected: usize,
    name: Entity<InputState>,
    code: Option<(Arc<Image>, String)>,
    working: bool,
    error: Option<SharedString>,
}

impl EventEmitter<Paired> for PairFlow {}

impl PairFlow {
    fn new(
        store: Entity<QuotaStore>,
        endpoints: Vec<(Mode, Value)>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let name = cx.new(|cx| InputState::new(window, cx).default_value("iPhone"));
        Self {
            store,
            endpoints,
            selected: 0,
            name,
            code: None,
            working: false,
            error: None,
        }
    }

    fn create(&mut self, cx: &mut Context<Self>) {
        let label = self.name.read(cx).value().trim().to_owned();
        if label.is_empty() {
            self.error = Some("Name the device first.".into());
            cx.notify();
            return;
        }
        self.working = true;
        self.error = None;
        cx.notify();
        let endpoint = self.endpoints[self.selected].1.clone();
        let request = self.store.read(cx).host().call(
            Method::POST,
            "/v2/clients".into(),
            Some(json!({
                "label": label,
                "scope": "read",
                "expires_in_seconds": sharing::ACCESS_SECONDS,
            })),
        );
        cx.spawn(async move |this, cx| {
            let result = async {
                let created = request.await?;
                let payload = sharing::pairing_payload(&created, &endpoint)?;
                let svg = sharing::qr_svg(&payload)?;
                let expires = created["client"]["expires_at"]
                    .as_str()
                    .and_then(|at| OffsetDateTime::parse(at, &Rfc3339).ok())
                    .map_or_else(String::new, |at| {
                        format!("{} {}", &at.month().to_string()[..3], at.day())
                    });
                anyhow::Ok((Arc::new(Image::from_bytes(ImageFormat::Svg, svg)), expires))
            }
            .await;
            let _ = this.update(cx, |this, cx| {
                this.working = false;
                match result {
                    Ok(code) => {
                        this.code = Some(code);
                        cx.emit(Paired);
                    }
                    Err(error) => {
                        this.error =
                            Some(format!("Couldn’t create a pairing code: {error:#}.").into())
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }
}

impl Render for PairFlow {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx).clone();
        let title = div()
            .text_size(px(16.))
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(p.text_strong);
        let body = match &self.code {
            Some((image, expires)) => div()
                .flex()
                .flex_col()
                .items_center()
                .gap(px(12.))
                .child(title.child("Scan with your iPhone"))
                // QR readers need dark modules on a light background in any theme.
                .child(
                    div()
                        .p(px(8.))
                        .rounded(px(12.))
                        .bg(white())
                        .child(img(image.clone()).size(px(240.))),
                )
                .child(
                    note(
                        format!(
                            "Open Quotio on your iPhone and scan this code. It gives read-only access to quota until {expires}."
                        ),
                        p.text_sub,
                    )
                    .text_center(),
                )
                .child(
                    note(
                        "Anyone who sees this code can read your quota. Close this window when you’re done.",
                        p.text_soft,
                    )
                    .text_center(),
                ),
            None => div()
                .flex()
                .flex_col()
                .gap(px(16.))
                .child(title.child("Pair iPhone"))
                .child(field("Device name", text_field(&self.name, &p), &p))
                .when(self.endpoints.len() > 1, |s| {
                    s.child(field(
                        "Connection",
                        div().flex().gap(px(8.)).children(
                            self.endpoints.iter().enumerate().map(|(i, (mode, _))| {
                                let active = i == self.selected;
                                div()
                                    .id(SharedString::from(format!("pair-mode-{i}")))
                                    .px(px(12.))
                                    .py(px(6.))
                                    .rounded(px(8.))
                                    .border_1()
                                    .cursor_pointer()
                                    .text_size(px(13.))
                                    .font_weight(FontWeight::MEDIUM)
                                    .map(|s| {
                                        if active {
                                            s.border_color(p.text_strong).text_color(p.text_strong)
                                        } else {
                                            s.border_color(p.stroke_soft).text_color(p.text_sub)
                                        }
                                    })
                                    .child(mode.label())
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.selected = i;
                                        cx.notify();
                                    }))
                            }),
                        ),
                        &p,
                    ))
                }),
        };
        let footer = match &self.code {
            Some(_) => dialog_footer().child(
                button("done", "Done", ButtonKind::Primary, &p)
                    .on_click(|_, window, cx: &mut App| window.close_dialog(cx)),
            ),
            None => dialog_footer()
                .child(
                    button("cancel", "Cancel", ButtonKind::Secondary, &p)
                        .on_click(|_, window, cx: &mut App| window.close_dialog(cx)),
                )
                .child(
                    button(
                        "create",
                        if self.working {
                            "Creating…"
                        } else {
                            "Show pairing code"
                        },
                        ButtonKind::Primary,
                        &p,
                    )
                    .when(!self.working, |s| {
                        s.on_click(cx.listener(|this, _, _, cx| this.create(cx)))
                    }),
                ),
        };
        div()
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(body)
            .when_some(self.error.clone(), |s, error| s.child(note(error, p.error)))
            .child(footer)
    }
}
