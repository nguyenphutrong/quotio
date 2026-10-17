//! Add-account flow, shown in a dialog: pick a provider, then sign in with a
//! browser, enter an API key, point at a CLI's login folder, or scan for logins.
//! Mirrors the macOS connect menu and sheets, using the same `/v2` calls.
use std::{sync::Arc, time::Duration};

use anyhow::{Context as _, Result};
use gpui_kit::assets::IconName;
use gpui_kit::component::WindowExt as _;
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::notification::Notification;
use gpui_kit::{
    AnyElement, App, AppContext as _, ClipboardItem, Context, Entity, EventEmitter, Focusable as _,
    FontWeight, InteractiveElement, IntoElement, ParentElement, Render, SharedString,
    StatefulInteractiveElement, Styled, Subscription, Task, Window, div,
    prelude::FluentBuilder as _, px,
};
use serde::Deserialize;
use serde_json::{Map, Value, json};

use crate::catalog::{Provider, ProviderList, SettingField};
use crate::host::{HostClient, HostError, Method};
use crate::store::QuotaStore;
use crate::theme::{Palette, palette};
use crate::ui::{ButtonKind, button, field, icon, note, provider_logo, text_field};

/// Read the provider catalog. Only providers this platform can connect are kept.
pub fn load_catalog(host: Arc<dyn HostClient>) -> impl Future<Output = Result<Vec<Provider>>> {
    let request = host.call(Method::GET, "/v2/providers".into(), None);
    async move {
        let list: ProviderList = serde_json::from_value(request.await?)?;
        let mut providers: Vec<Provider> = list
            .providers
            .into_iter()
            .filter(Provider::connectable)
            .collect();
        providers.sort_by_key(|p| p.display_name.to_lowercase());
        Ok(providers)
    }
}

#[derive(Clone, Debug, Deserialize)]
struct Session {
    id: String,
    workflow: String,
    url: String,
    user_code: Option<String>,
    status: String,
    error_code: Option<String>,
}

enum Choice {
    Text(Entity<InputState>),
    Pick(Vec<String>, Option<String>),
}

enum Step {
    Pick,
    Methods(Provider),
    ApiKey {
        provider: Provider,
        name: Entity<InputState>,
        key: Entity<InputState>,
        fields: Vec<(SettingField, Choice)>,
    },
    Folder {
        provider: Provider,
        kind: String,
        name: Entity<InputState>,
        folder: Entity<InputState>,
        /// Logins found in the folder when it holds more than one.
        candidates: Vec<(String, Value)>,
    },
    Browser {
        provider: Provider,
        session: Option<Session>,
        code: Entity<InputState>,
    },
    Scan {
        provider: Provider,
        summary: Option<String>,
    },
}

pub struct ConnectFlow {
    store: Entity<QuotaStore>,
    catalog: Option<Vec<Provider>>,
    step: Step,
    search: Entity<InputState>,
    error: Option<SharedString>,
    working: bool,
    poll: Option<Task<()>>,
    _subscriptions: Vec<Subscription>,
}

/// Emitted when an account was added; the dialog closes.
pub struct Connected;

impl EventEmitter<Connected> for ConnectFlow {}

impl ConnectFlow {
    /// `provider` skips the picker, e.g. for "Sign in again".
    pub fn new(
        store: Entity<QuotaStore>,
        catalog: Option<Vec<Provider>>,
        provider: Option<&str>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search providers"));
        let subscriptions = vec![cx.subscribe(&search, |_, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        })];
        let mut this = Self {
            store,
            catalog,
            step: Step::Pick,
            search,
            error: None,
            working: false,
            poll: None,
            _subscriptions: subscriptions,
        };
        match &this.catalog {
            Some(catalog) => {
                if let Some(provider) = provider.and_then(|id| catalog.iter().find(|p| p.id == id))
                {
                    this.choose(provider.clone(), window, cx);
                }
            }
            None => this.fetch_catalog(provider.map(str::to_owned), window, cx),
        }
        this
    }

    pub fn focus_search(&self, window: &mut Window, cx: &mut App) {
        if matches!(self.step, Step::Pick) {
            self.search.read(cx).focus_handle(cx).focus(window, cx);
        }
    }

    fn host(&self, cx: &App) -> Arc<dyn HostClient> {
        self.store.read(cx).host()
    }

    fn fetch_catalog(&mut self, then: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        let request = load_catalog(self.host(cx));
        cx.spawn_in(window, async move |this, cx| {
            let result = request.await;
            let _ = this.update_in(cx, |this, window, cx| {
                match result {
                    Ok(catalog) => {
                        let provider =
                            then.and_then(|id| catalog.iter().find(|p| p.id == id).cloned());
                        this.catalog = Some(catalog);
                        if let Some(provider) = provider {
                            this.choose(provider, window, cx);
                        }
                    }
                    Err(error) => {
                        this.error = Some(format!("Couldn’t load providers: {error:#}.").into())
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// Go to the provider's methods, or straight to the only one it has.
    fn choose(&mut self, provider: Provider, window: &mut Window, cx: &mut Context<Self>) {
        let methods = [
            provider.browser_sign_in(),
            provider.api_key(),
            provider.local_login().is_some(),
            provider.scan(),
        ];
        if methods.iter().filter(|m| **m).count() > 1 {
            self.go(Step::Methods(provider), cx);
        } else if provider.browser_sign_in() {
            self.browser(provider, window, cx);
        } else if provider.api_key() {
            self.api_key(provider, window, cx);
        } else if provider.local_login().is_some() {
            self.folder(provider, window, cx);
        } else {
            self.scan(provider, window, cx);
        }
    }

    fn go(&mut self, step: Step, cx: &mut Context<Self>) {
        self.cancel_session(cx);
        self.step = step;
        self.error = None;
        self.working = false;
        cx.notify();
    }

    fn back(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let provider = match &self.step {
            Step::Pick => return,
            Step::Methods(_) => None,
            Step::ApiKey { provider, .. }
            | Step::Folder { provider, .. }
            | Step::Browser { provider, .. }
            | Step::Scan { provider, .. } => Some(provider.clone()),
        };
        match provider {
            Some(provider) if self.has_choices(&provider) => self.go(Step::Methods(provider), cx),
            _ => self.go(Step::Pick, cx),
        }
        self.search
            .update(cx, |s, cx| s.focus_handle(cx).focus(window, cx));
    }

    fn has_choices(&self, p: &Provider) -> bool {
        [
            p.browser_sign_in(),
            p.api_key(),
            p.local_login().is_some(),
            p.scan(),
        ]
        .iter()
        .filter(|m| **m)
        .count()
            > 1
    }

    /// Stop a browser sign-in that is still waiting, e.g. when the dialog closes.
    pub fn cancel_session(&mut self, cx: &mut Context<Self>) {
        self.poll = None;
        if let Step::Browser {
            session: Some(session),
            ..
        } = &self.step
            && matches!(session.status.as_str(), "waiting" | "processing")
        {
            let request = self.host(cx).call(
                Method::DELETE,
                format!("/v2/auth/sessions/{}", session.id),
                None,
            );
            cx.background_spawn(async move {
                let _ = request.await;
            })
            .detach();
        }
    }

    /// Run a step's work; show its error in the dialog, or finish on success.
    fn submit(
        &mut self,
        work: impl Future<Output = Result<String>> + 'static,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.working = true;
        self.error = None;
        cx.notify();
        cx.spawn_in(window, async move |this, cx| {
            let result = work.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.working = false;
                match result {
                    Ok(message) => this.finish(message, window, cx),
                    Err(error) => this.error = Some(sentence(&error).into()),
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn finish(&mut self, message: String, window: &mut Window, cx: &mut Context<Self>) {
        self.store.update(cx, |store, cx| store.reload(cx));
        window.push_notification(Notification::success(message), cx);
        cx.emit(Connected);
    }

    // MARK: steps

    fn api_key(&mut self, provider: Provider, window: &mut Window, cx: &mut Context<Self>) {
        let name = cx.new(|cx| {
            InputState::new(window, cx).placeholder(format!("{} account", provider.display_name))
        });
        let key = cx.new(|cx| {
            InputState::new(window, cx)
                .masked(true)
                .placeholder("Paste the key")
        });
        let fields = provider
            .capabilities
            .settings
            .iter()
            .map(|f| {
                let choice = match &f.values {
                    Some(values) => Choice::Pick(values.clone(), None),
                    None => Choice::Text(cx.new(|cx| InputState::new(window, cx))),
                };
                (f.clone(), choice)
            })
            .collect();
        name.update(cx, |s, cx| s.focus_handle(cx).focus(window, cx));
        self.go(
            Step::ApiKey {
                provider,
                name,
                key,
                fields,
            },
            cx,
        );
    }

    fn save_api_key(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Step::ApiKey {
            provider,
            name,
            key,
            fields,
        } = &self.step
        else {
            return;
        };
        let label = name.read(cx).value().trim().to_owned();
        let api_key = key.read(cx).value().trim().to_owned();
        if label.is_empty() || api_key.is_empty() {
            self.error = Some("Enter a name and the key.".into());
            cx.notify();
            return;
        }
        let mut body = json!({ "provider": provider.id, "label": label, "api_key": api_key });
        let mut settings = Map::new();
        for (field, choice) in fields {
            let value = match choice {
                Choice::Text(input) => Some(input.read(cx).value().trim().to_owned()),
                Choice::Pick(_, picked) => picked.clone(),
            }
            .filter(|v| !v.is_empty());
            match (value, field.field_path.strip_prefix("settings.")) {
                (None, _) if field.required => {
                    self.error = Some(format!("Enter {}.", field_label(&field.name)).into());
                    cx.notify();
                    return;
                }
                (None, _) => {}
                (Some(value), Some(name)) => {
                    settings.insert(name.to_owned(), value.into());
                }
                (Some(value), None) => body[&field.field_path] = value.into(),
            }
        }
        if !settings.is_empty() {
            body["settings"] = settings.into();
        }
        let host = self.host(cx);
        let (id, display) = (provider.id.clone(), provider.display_name.clone());
        self.submit(
            async move {
                ensure_tracked(&host, &id).await?;
                host.mutate(Method::POST, "/v2/accounts".into(), Some(body))
                    .await?;
                Ok(format!("Added a {display} account."))
            },
            window,
            cx,
        );
    }

    fn folder(&mut self, provider: Provider, window: &mut Window, cx: &mut Context<Self>) {
        let Some(reference) = provider.local_login() else {
            return;
        };
        let kind = reference.kind.clone();
        let hint = format!("~/.{}-work", provider.id);
        let name = cx.new(|cx| InputState::new(window, cx).placeholder("Optional"));
        let folder = cx.new(|cx| InputState::new(window, cx).placeholder(hint));
        folder.update(cx, |s, cx| s.focus_handle(cx).focus(window, cx));
        self.go(
            Step::Folder {
                provider,
                kind,
                name,
                folder,
                candidates: Vec::new(),
            },
            cx,
        );
    }

    /// Register the folder's login. A folder with several logins comes back with
    /// `entry_required`; list them so the user can pick one.
    fn save_folder(&mut self, pick: Option<Value>, window: &mut Window, cx: &mut Context<Self>) {
        let Step::Folder {
            provider,
            kind,
            name,
            folder,
            ..
        } = &self.step
        else {
            return;
        };
        let dir = expand_home(folder.read(cx).value().trim());
        if dir.is_empty() {
            self.error = Some("Enter the folder the CLI uses.".into());
            cx.notify();
            return;
        }
        let label = Some(name.read(cx).value().trim().to_owned()).filter(|l| !l.is_empty());
        let body = match pick {
            Some(source) => source,
            None => {
                let mut body = json!({ "kind": kind, "config_dir": dir });
                if let Some(label) = &label {
                    body["label"] = label.clone().into();
                }
                body
            }
        };
        let host = self.host(cx);
        let (id, kind) = (provider.id.clone(), kind.clone());
        let display = provider.display_name.clone();
        self.working = true;
        self.error = None;
        cx.notify();
        cx.spawn_in(window, async move |this, cx| {
            let result: Result<String> = async {
                ensure_tracked(&host, &id).await?;
                let added = host
                    .mutate(Method::POST, "/v2/sources".into(), Some(body.clone()))
                    .await;
                match added {
                    Err(error) if HostError::code(&error) == Some("permission_required") => {
                        host.mutate(Method::POST, "/v2/sources/authorize".into(), Some(body))
                            .await?;
                    }
                    other => {
                        other?;
                    }
                }
                Ok(format!("Added a {} login.", crate::providers::display_name(&id)))
            }
            .await;
            let candidates = match &result {
                Err(error) if HostError::code(error) == Some("entry_required") => {
                    let found = host
                        .call(
                            Method::POST,
                            "/v2/sources/discover".into(),
                            Some(json!({
                                "provider": id,
                                "kind": kind,
                                "config_dir": dir,
                                "inspect": true,
                            })),
                        )
                        .await;
                    found.ok().map(|found| {
                        found["candidates"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(|c| {
                                let mut source = c["source"].clone();
                                if let Some(label) = &label {
                                    source["label"] = label.clone().into();
                                }
                                Some((c["label"].as_str()?.to_owned(), source))
                            })
                            .collect::<Vec<_>>()
                    })
                }
                _ => None,
            };
            let _ = this.update_in(cx, |this, window, cx| {
                this.working = false;
                match (result, candidates) {
                    (Ok(message), _) => this.finish(message, window, cx),
                    (Err(_), Some(found)) if !found.is_empty() => {
                        if let Step::Folder { candidates, .. } = &mut this.step {
                            *candidates = found;
                        }
                        this.error = Some("This folder has several logins. Choose one.".into());
                    }
                    (Err(error), _) if HostError::code(&error) == Some("account_not_found") => {
                        this.error = Some(
                            format!(
                                "No {display} login in this folder. Sign in with the CLI there first."
                            )
                            .into(),
                        );
                    }
                    (Err(error), _) => this.error = Some(sentence(&error).into()),
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn scan(&mut self, provider: Provider, window: &mut Window, cx: &mut Context<Self>) {
        let host = self.host(cx);
        let id = provider.id.clone();
        self.go(
            Step::Scan {
                provider,
                summary: None,
            },
            cx,
        );
        self.working = true;
        cx.spawn_in(window, async move |this, cx| {
            let result: Result<Value> = async {
                ensure_tracked(&host, &id).await?;
                host.mutate(
                    Method::POST,
                    "/v2/discovery".into(),
                    Some(json!({ "providers": [id], "restore_removed": true })),
                )
                .await
            }
            .await;
            let _ = this.update_in(cx, |this, _, cx| {
                this.working = false;
                this.store.update(cx, |store, cx| store.reload(cx));
                match result {
                    Ok(report) => {
                        let summary = scan_summary(&report);
                        if let Step::Scan { summary: s, .. } = &mut this.step {
                            *s = Some(summary);
                        }
                    }
                    Err(error) => this.error = Some(sentence(&error).into()),
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn browser(&mut self, provider: Provider, window: &mut Window, cx: &mut Context<Self>) {
        let code = cx.new(|cx| InputState::new(window, cx).placeholder("Paste the code"));
        let host = self.host(cx);
        let id = provider.id.clone();
        self.go(
            Step::Browser {
                provider,
                session: None,
                code,
            },
            cx,
        );
        self.working = true;
        self.poll = Some(cx.spawn_in(window, async move |this, cx| {
            let started: Result<Session> = async {
                ensure_tracked(&host, &id).await?;
                let session = host
                    .call(
                        Method::POST,
                        "/v2/auth/sessions".into(),
                        Some(json!({ "provider": id })),
                    )
                    .await?;
                Ok(serde_json::from_value(session)?)
            }
            .await;
            let Ok(Some(mut session)) = this.update(cx, |this, cx| {
                this.working = false;
                cx.notify();
                match started {
                    Ok(session) => {
                        this.set_session(session.clone());
                        Some(session)
                    }
                    Err(error) => {
                        this.error = Some(sentence(&error).into());
                        None
                    }
                }
            }) else {
                return;
            };
            // Wait for the provider to send the user back, or for the code.
            while matches!(session.status.as_str(), "waiting" | "processing") {
                cx.background_executor()
                    .timer(Duration::from_millis(700))
                    .await;
                let next = host
                    .call(
                        Method::GET,
                        format!("/v2/auth/sessions/{}", session.id),
                        None,
                    )
                    .await
                    .and_then(|v| Ok(serde_json::from_value::<Session>(v)?));
                match next {
                    Ok(next) => session = next,
                    Err(_) => continue,
                }
                let _ = this.update(cx, |this, cx| {
                    this.set_session(session.clone());
                    cx.notify();
                });
            }
            let _ = this.update_in(cx, |this, window, cx| {
                match session.status.as_str() {
                    "completed" => this.finish(
                        format!("Signed in to {}.", crate::providers::display_name(&id)),
                        window,
                        cx,
                    ),
                    "cancelled" => {}
                    "expired" => {
                        this.error = Some("The sign-in expired. Start again.".into());
                    }
                    _ => {
                        let error = HostError {
                            code: session
                                .error_code
                                .clone()
                                .unwrap_or_else(|| "oauth_failed".into()),
                        };
                        this.error = Some(format!("{}.", capitalize(&error.to_string())).into());
                    }
                }
                cx.notify();
            });
        }));
    }

    fn set_session(&mut self, new: Session) {
        if let Step::Browser { session, .. } = &mut self.step {
            *session = Some(new);
        }
    }

    fn send_code(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Step::Browser {
            session: Some(session),
            code,
            ..
        } = &self.step
        else {
            return;
        };
        let value = code.read(cx).value().trim().to_owned();
        if value.is_empty() {
            return;
        }
        let request = self.host(cx).call(
            Method::POST,
            format!("/v2/auth/sessions/{}/callback", session.id),
            Some(json!({ "code": value })),
        );
        self.working = true;
        self.error = None;
        cx.notify();
        // The poll loop picks up the result.
        cx.spawn_in(window, async move |this, cx| {
            let result = request.await;
            let _ = this.update(cx, |this, cx| {
                this.working = false;
                if let Err(error) = result {
                    this.error = Some(sentence(&error).into());
                }
                cx.notify();
            });
        })
        .detach();
    }

    // MARK: rendering

    fn header(&self, title: String, subtitle: String, p: &Palette) -> impl IntoElement {
        div()
            .flex()
            .flex_col()
            .gap(px(6.))
            .child(
                div()
                    .text_size(px(18.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(p.text_strong)
                    .child(title),
            )
            .child(
                div()
                    .text_size(px(14.))
                    .text_color(p.text_sub)
                    .child(subtitle),
            )
    }

    fn header_only(&self, title: String, p: &Palette) -> AnyElement {
        self.header(title, "Your password goes only to the provider.".into(), p)
            .into_any_element()
    }

    fn pick(&self, p: &Palette, cx: &mut Context<Self>) -> AnyElement {
        let query = self.search.read(cx).value().trim().to_lowercase();
        let rows: Vec<AnyElement> = self
            .catalog
            .iter()
            .flatten()
            .filter(|provider| {
                query.is_empty()
                    || provider.display_name.to_lowercase().contains(&query)
                    || provider.id.contains(&query)
            })
            .enumerate()
            .map(|(i, provider)| {
                let target = provider.clone();
                option_row(
                    SharedString::from(format!("provider-{}", provider.id)),
                    provider_logo(&provider.id, 18., None, p),
                    provider.display_name.clone(),
                    methods_summary(provider),
                    i > 0,
                    p,
                )
                .on_click(
                    cx.listener(move |this, _, window, cx| this.choose(target.clone(), window, cx)),
                )
                .into_any_element()
            })
            .collect();
        let empty = rows.is_empty();
        div()
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(self.header(
                "Add an account".into(),
                "Sign-ins and keys stay on this computer.".into(),
                p,
            ))
            .child(
                div()
                    .h(px(36.))
                    .flex()
                    .items_center()
                    .gap(px(2.))
                    .pl(px(10.))
                    .rounded(px(10.))
                    .bg(p.bg_weak)
                    .child(icon(IconName::Search, 16., p.text_soft))
                    .child(
                        Input::new(&self.search)
                            .appearance(false)
                            .cleanable(true)
                            .text_size(px(14.)),
                    ),
            )
            .child(
                div()
                    .id("providers")
                    .max_h(px(360.))
                    .overflow_y_scroll()
                    .rounded(px(16.))
                    .border_1()
                    .border_color(p.stroke_soft)
                    .children(rows)
                    .when(empty, |s| {
                        s.child(
                            div()
                                .p(px(16.))
                                .text_size(px(14.))
                                .text_color(p.text_soft)
                                .child(if self.catalog.is_none() {
                                    "Loading providers…"
                                } else {
                                    "No provider matches."
                                }),
                        )
                    }),
            )
            .into_any_element()
    }

    fn methods(&self, provider: &Provider, p: &Palette, cx: &mut Context<Self>) -> AnyElement {
        let name = provider.display_name.clone();
        let mut rows: Vec<AnyElement> = Vec::new();
        let mut add =
            |id: &'static str,
             glyph: IconName,
             title: String,
             help: String,
             go: fn(&mut Self, Provider, &mut Window, &mut Context<Self>),
             cx: &mut Context<Self>| {
                let target = provider.clone();
                let divider = !rows.is_empty();
                rows.push(
                    option_row(id, icon(glyph, 18., p.text_sub), title, help, divider, p)
                        .on_click(cx.listener(move |this, _, window, cx| {
                            go(this, target.clone(), window, cx)
                        }))
                        .into_any_element(),
                );
            };
        if provider.browser_sign_in() {
            add(
                "browser",
                IconName::Globe,
                "Sign in with your browser".into(),
                format!("Opens {name}’s sign-in page."),
                Self::browser,
                cx,
            );
        }
        if provider.api_key() {
            add(
                "api-key",
                IconName::KeyRound,
                "Add an API key".into(),
                format!("Uses a key from your {name} dashboard."),
                Self::api_key,
                cx,
            );
        }
        if let Some(reference) = provider.local_login() {
            add(
                "folder",
                IconName::Folder,
                "Use another login folder".into(),
                format!(
                    "A folder set with {} for a second {name} login.",
                    reference.config_dir_env.as_deref().unwrap_or("the CLI")
                ),
                Self::folder,
                cx,
            );
        }
        if provider.scan() {
            add(
                "scan",
                IconName::RefreshCw,
                "Scan this computer".into(),
                format!("Finds {name} logins your CLI already uses."),
                Self::scan,
                cx,
            );
        }
        div()
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(self.header(
                format!("Connect {name}"),
                "Choose how Quotio reads this account.".into(),
                p,
            ))
            .child(
                div()
                    .rounded(px(16.))
                    .border_1()
                    .border_color(p.stroke_soft)
                    .children(rows),
            )
            .into_any_element()
    }

    fn api_key_form(&self, p: &Palette, cx: &mut Context<Self>) -> AnyElement {
        let Step::ApiKey {
            provider,
            name,
            key,
            fields,
        } = &self.step
        else {
            return div().into_any_element();
        };
        let extra: Vec<AnyElement> = fields
            .iter()
            .enumerate()
            .map(|(index, (setting, choice))| {
                let label = if setting.required {
                    field_label(&setting.name)
                } else {
                    format!("{} (optional)", field_label(&setting.name))
                };
                let control = match choice {
                    Choice::Text(input) => text_field(input, p).into_any_element(),
                    Choice::Pick(values, picked) => div()
                        .flex()
                        .gap(px(6.))
                        .children(values.iter().map(|value| {
                            let selected = picked.as_ref() == Some(value);
                            let chosen = value.clone();
                            div()
                                .id(SharedString::from(format!("{}-{value}", setting.name)))
                                .h(px(32.))
                                .px(px(12.))
                                .flex()
                                .items_center()
                                .rounded_full()
                                .border_1()
                                .cursor_pointer()
                                .text_size(px(14.))
                                .font_weight(FontWeight::MEDIUM)
                                .map(|s| {
                                    if selected {
                                        s.bg(p.text_strong)
                                            .border_color(p.text_strong)
                                            .text_color(p.on_strong)
                                    } else {
                                        s.border_color(p.stroke_soft).text_color(p.text_strong)
                                    }
                                })
                                .child(value.clone())
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if let Step::ApiKey { fields, .. } = &mut this.step
                                        && let Some((_, Choice::Pick(_, picked))) =
                                            fields.get_mut(index)
                                    {
                                        *picked = (picked.as_ref() != Some(&chosen))
                                            .then(|| chosen.clone());
                                        cx.notify();
                                    }
                                }))
                        }))
                        .into_any_element(),
                };
                field(label, control, p).into_any_element()
            })
            .collect();
        div()
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(self.header(
                format!("Add a {} API key", provider.display_name),
                "Quotio checks the key with the provider before saving it.".into(),
                p,
            ))
            .child(field("Account name", text_field(name, p), p))
            .child(field("API key", text_field(key, p), p))
            .children(extra)
            .into_any_element()
    }

    fn folder_form(&self, p: &Palette, cx: &mut Context<Self>) -> AnyElement {
        let Step::Folder {
            provider,
            name,
            folder,
            candidates,
            ..
        } = &self.step
        else {
            return div().into_any_element();
        };
        let env = provider
            .local_login()
            .and_then(|r| r.config_dir_env.clone())
            .unwrap_or_default();
        div()
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(self.header(
                format!("Use another {} login", provider.display_name),
                format!(
                    "Point at the folder you set with {env}. Quotio reads the login there and never changes it."
                ),
                p,
            ))
            .child(field("Login folder", text_field(folder, p), p))
            .child(field("Display name", text_field(name, p), p))
            .when(!candidates.is_empty(), |s| {
                s.child(
                    div()
                        .rounded(px(16.))
                        .border_1()
                        .border_color(p.stroke_soft)
                        .children(candidates.iter().enumerate().map(|(i, (label, source))| {
                            let source = source.clone();
                            option_row(
                                SharedString::from(format!("candidate-{i}")),
                                icon(IconName::User, 18., p.text_sub),
                                label.clone(),
                                "Add this login".into(),
                                i > 0,
                                p,
                            )
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.save_folder(Some(source.clone()), window, cx)
                            }))
                        })),
                )
            })
            .into_any_element()
    }

    fn browser_view(&self, p: &Palette) -> AnyElement {
        let Step::Browser {
            provider,
            session,
            code,
        } = &self.step
        else {
            return div().into_any_element();
        };
        let name = provider.display_name.clone();
        let body = match session {
            None if self.error.is_some() => {
                return self.header_only(format!("Sign in to {name}"), p);
            }
            None => div()
                .text_size(px(14.))
                .text_color(p.text_sub)
                .child("Starting sign-in…")
                .into_any_element(),
            Some(session) if !matches!(session.status.as_str(), "waiting" | "processing") => {
                return self.header_only(format!("Sign in to {name}"), p);
            }
            Some(session) => {
                let url = session.url.clone();
                let copy = url.clone();
                let link = div()
                    .flex()
                    .gap(px(8.))
                    .child(
                        button("open-link", "Open sign-in page", ButtonKind::Primary, p)
                            .on_click(move |_, _, cx| cx.open_url(&url)),
                    )
                    .child(
                        button("copy-link", "Copy link", ButtonKind::Secondary, p).on_click(
                            move |_, window, cx| {
                                cx.write_to_clipboard(ClipboardItem::new_string(copy.clone()));
                                window.push_notification(Notification::info("Link copied."), cx);
                            },
                        ),
                    );
                let waiting = |text: String| {
                    div()
                        .flex()
                        .items_center()
                        .gap(px(8.))
                        .text_size(px(12.))
                        .text_color(p.text_soft)
                        .child(icon(IconName::LoaderCircle, 14., p.text_soft))
                        .child(text)
                };
                match session.workflow.as_str() {
                    "device_code" => {
                        let user_code = session.user_code.clone().unwrap_or_default();
                        let copy_code = user_code.clone();
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(12.))
                            .child(
                                div()
                                    .text_size(px(14.))
                                    .text_color(p.text_sub)
                                    .child("Enter this code on the page that opens:"),
                            )
                            .child(
                                div()
                                    .id("user-code")
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .gap(px(10.))
                                    .py(px(14.))
                                    .rounded(px(12.))
                                    .bg(p.bg_weak)
                                    .cursor_pointer()
                                    .child(
                                        div()
                                            .text_size(px(26.))
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .font_family("monospace")
                                            .text_color(p.text_strong)
                                            .child(user_code),
                                    )
                                    .child(icon(IconName::Copy, 16., p.text_soft))
                                    .on_click(move |_, window, cx| {
                                        cx.write_to_clipboard(ClipboardItem::new_string(
                                            copy_code.clone(),
                                        ));
                                        window.push_notification(
                                            Notification::info("Code copied."),
                                            cx,
                                        );
                                    }),
                            )
                            .child(link)
                            .child(waiting(format!("Waiting for {name} to confirm…")))
                            .into_any_element()
                    }
                    "manual_code" => div()
                        .flex()
                        .flex_col()
                        .gap(px(12.))
                        .child(
                            div()
                                .text_size(px(14.))
                                .text_color(p.text_sub)
                                .child(format!(
                                    "Sign in on the page that opens, then paste the code {name} shows you."
                                )),
                        )
                        .child(link)
                        .child(field("Authorization code", text_field(code, p), p))
                        .into_any_element(),
                    _ => div()
                        .flex()
                        .flex_col()
                        .gap(px(12.))
                        .child(
                            div()
                                .text_size(px(14.))
                                .text_color(p.text_sub)
                                .child(format!(
                                    "Sign in on the page that opens. Quotio finishes when {name} sends you back."
                                )),
                        )
                        .child(link)
                        .child(waiting("Waiting for the browser…".into()))
                        .into_any_element(),
                }
            }
        };
        div()
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(self.header(
                format!("Sign in to {name}"),
                "Your password goes only to the provider.".into(),
                p,
            ))
            .child(body)
            .into_any_element()
    }

    fn scan_view(&self, provider: &Provider, summary: Option<&String>, p: &Palette) -> AnyElement {
        div()
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(self.header(
                format!("Scan for {} logins", provider.display_name),
                "Quotio looks where the CLI keeps its login. Nothing is uploaded.".into(),
                p,
            ))
            .child(
                div()
                    .text_size(px(14.))
                    .text_color(p.text_sub)
                    .child(match summary {
                        Some(summary) => summary.clone(),
                        None if self.working => "Scanning…".into(),
                        None => String::new(),
                    }),
            )
            .into_any_element()
    }

    fn footer(&self, p: &Palette, cx: &mut Context<Self>) -> impl IntoElement {
        let primary: Option<(&'static str, fn(&mut Self, &mut Window, &mut Context<Self>))> =
            match &self.step {
                Step::ApiKey { .. } => Some(("Add account", Self::save_api_key)),
                Step::Folder { .. } => Some(("Add login", |this, window, cx| {
                    this.save_folder(None, window, cx)
                })),
                Step::Browser {
                    session: Some(session),
                    ..
                } if session.workflow == "manual_code" && session.status == "waiting" => {
                    Some(("Complete", Self::send_code))
                }
                _ => None,
            };
        let done = matches!(
            &self.step,
            Step::Scan {
                summary: Some(_),
                ..
            }
        );
        let retry = matches!(&self.step, Step::Browser { .. }) && self.error.is_some();
        div()
            .flex()
            .items_center()
            .gap(px(12.))
            .pt(px(4.))
            .when(!matches!(self.step, Step::Pick), |s| {
                s.child(
                    div()
                        .id("back")
                        .cursor_pointer()
                        .text_size(px(14.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_sub)
                        .child("Back")
                        .on_click(cx.listener(|this, _, window, cx| this.back(window, cx))),
                )
            })
            .child(div().flex_1())
            .when(retry, |s| {
                s.child(
                    button("retry", "Try again", ButtonKind::Primary, p).on_click(cx.listener(
                        |this, _, window, cx| {
                            if let Step::Browser { provider, .. } = &this.step {
                                let provider = provider.clone();
                                this.browser(provider, window, cx);
                            }
                        },
                    )),
                )
            })
            .when(done, |s| {
                s.child(
                    button("done", "Done", ButtonKind::Primary, p)
                        .on_click(|_, window, cx| window.close_dialog(cx)),
                )
            })
            .when_some(primary, |s, (label, action)| {
                s.child(
                    button("primary", label, ButtonKind::Primary, p)
                        .when(self.working, |s| s.opacity(0.5))
                        .on_click(cx.listener(move |this, _, window, cx| {
                            if !this.working {
                                action(this, window, cx)
                            }
                        })),
                )
            })
    }
}

impl Render for ConnectFlow {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx).clone();
        let body = match &self.step {
            Step::Pick => self.pick(&p, cx),
            Step::Methods(provider) => {
                let provider = provider.clone();
                self.methods(&provider, &p, cx)
            }
            Step::ApiKey { .. } => self.api_key_form(&p, cx),
            Step::Folder { .. } => self.folder_form(&p, cx),
            Step::Browser { .. } => self.browser_view(&p),
            Step::Scan { provider, summary } => self.scan_view(provider, summary.as_ref(), &p),
        };
        div()
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(body)
            .when_some(self.error.clone(), |s, error| s.child(note(error, p.error)))
            .child(self.footer(&p, cx))
    }
}

/// A row in the provider and method lists.
fn option_row(
    id: impl Into<gpui_kit::ElementId>,
    leading: impl IntoElement,
    title: String,
    help: String,
    divider: bool,
    p: &Palette,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    div()
        .id(id)
        .flex()
        .items_center()
        .gap(px(12.))
        .px(px(16.))
        .py(px(12.))
        .cursor_pointer()
        .hover(|s| s.bg(p.bg_weak))
        .when(divider, |s| s.border_t_1().border_color(p.stroke_soft))
        .child(
            div()
                .size(px(32.))
                .flex_none()
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(10.))
                .bg(p.bg_weak)
                .child(leading),
        )
        .child(
            div()
                .flex()
                .flex_col()
                .flex_1()
                .min_w_0()
                .gap(px(2.))
                .child(
                    div()
                        .text_size(px(14.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_strong)
                        .child(title),
                )
                .child(
                    div()
                        .truncate()
                        .text_size(px(12.))
                        .text_color(p.text_sub)
                        .child(help),
                ),
        )
        .child(icon(IconName::ChevronRight, 16., p.text_soft))
}

fn methods_summary(provider: &Provider) -> String {
    let mut ways = Vec::new();
    if provider.browser_sign_in() {
        ways.push("Browser sign-in");
    }
    if provider.api_key() {
        ways.push("API key");
    }
    if provider.local_login().is_some() || provider.scan() {
        ways.push("CLI login");
    }
    ways.join(" · ")
}

/// `organization_id` → `Organization ID`.
fn field_label(name: &str) -> String {
    name.split('_')
        .map(|word| match word {
            "id" => "ID".to_owned(),
            "url" => "URL".to_owned(),
            "arn" => "ARN".to_owned(),
            word => capitalize(word),
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn capitalize(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

fn sentence(error: &anyhow::Error) -> String {
    format!("{}.", capitalize(&format!("{error:#}")))
}

fn expand_home(path: &str) -> String {
    match (path.strip_prefix("~"), directories::BaseDirs::new()) {
        (Some(rest), Some(dirs)) if rest.is_empty() || rest.starts_with(['/', '\\']) => {
            format!("{}{rest}", dirs.home_dir().display())
        }
        _ => path.to_owned(),
    }
}

/// `{registered, failures}` from a discovery report, in words.
fn scan_summary(report: &Value) -> String {
    let count = |v: &Value| {
        v.as_array()
            .map_or_else(|| v.as_u64().unwrap_or(0) as usize, Vec::len)
    };
    let registered = count(&report["registered"]);
    let failures = count(&report["failures"]);
    let found = match registered {
        0 => "No new logins found.".to_owned(),
        1 => "Added 1 login.".to_owned(),
        n => format!("Added {n} logins."),
    };
    match failures {
        0 => found,
        n => format!("{found} {n} could not be read."),
    }
}

/// Connecting a provider the user paused turns tracking back on, as on macOS.
async fn ensure_tracked(host: &Arc<dyn HostClient>, provider: &str) -> Result<()> {
    let settings = host.call(Method::GET, "/v2/settings".into(), None).await?;
    let list = |key: &str| -> Vec<String> {
        settings[key]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect()
    };
    let mut disabled = list("disabled_providers");
    if !disabled.iter().any(|p| p == provider) {
        return Ok(());
    }
    disabled.retain(|p| p != provider);
    let mut enabled = list("enabled_providers");
    enabled.push(provider.to_owned());
    let revision = settings["revision"]
        .as_str()
        .context("settings without revision")?;
    host.call(
        Method::PATCH,
        "/v2/settings".into(),
        Some(json!({
            "revision": revision,
            "enabled_providers": enabled,
            "disabled_providers": disabled,
        })),
    )
    .await?;
    Ok(())
}
