//! Quotio for macOS, Windows and Linux: a tray popup and a settings window on GPUI,
//! backed by the Rust host from `apps/cli` running in this process.
mod app;
mod assets;
mod autostart;
mod catalog;
mod host;
mod model;
mod notifier;
mod prefs;
mod providers;
mod sharing;
mod store;
mod theme;
mod tray;
mod ui;
#[cfg(target_os = "linux")]
mod x11;

use std::{path::PathBuf, sync::Arc};

use anyhow::{Context as _, Result, bail};
use futures::StreamExt as _;
use gpui_kit::{App, AppContext as _, Entity, QuitMode, point, px};
use time::{Duration, UtcOffset};

use host::{EmbeddedHost, FixtureClient, HostClient, HostOptions};
use store::{Clock, QuotaStore};
use tray::{Tray, TrayEvent};

const USAGE: &str = "\
Usage: quotio-desktop [--demo | --fixture <snapshot.json>] [--show-menu] [--show-settings]

  --demo            Run the host with the deterministic mock provider only
  --fixture <path>  Render a saved /v2 snapshot without starting the host
  --show-menu       Open the quota popup at startup
  --show-settings   Open the settings window at startup";

#[derive(Default)]
struct Options {
    demo: bool,
    fixture: Option<PathBuf>,
    show_menu: bool,
    show_settings: bool,
}

fn parse_args() -> Result<Options> {
    let mut options = Options::default();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--demo" => options.demo = true,
            "--fixture" => options.fixture = Some(args.next().context(USAGE)?.into()),
            "--show-menu" => options.show_menu = true,
            "--show-settings" => options.show_settings = true,
            "-h" | "--help" => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            other => bail!("unknown argument {other}\n\n{USAGE}"),
        }
    }
    Ok(options)
}

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn")).init();
    let options = parse_args()?;
    // `time` can read the local offset only while the process is single-threaded.
    let offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);

    let (client, clock, host): (Arc<dyn HostClient>, Clock, Option<EmbeddedHost>) =
        match &options.fixture {
            Some(path) => {
                let snapshot = host::load_fixture(path)?;
                // Show the fixture as if it was fetched two minutes ago.
                let now = snapshot.generated_at + Duration::minutes(2);
                (Arc::new(FixtureClient(snapshot)), Clock::Frozen(now), None)
            }
            None => {
                let host = EmbeddedHost::start(HostOptions { demo: options.demo })?;
                (host.client(), Clock::System, Some(host))
            }
        };
    // The Linux tray talks D-Bus through Tokio, independently of the host.
    let tray_runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()?;
    let runtime = tray_runtime.handle().clone();

    // `run` blocks until the app quits and drops its closure after launch, so the
    // host and runtimes stay owned here.
    let application = gpui_kit::application()
        .with_assets(assets::AppAssets)
        .with_quit_mode(QuitMode::Explicit);
    // With the menu bar icon hidden, the Dock icon is the way back in.
    #[cfg(target_os = "macos")]
    application.on_reopen(app::open_settings);
    application.run(move |cx: &mut App| {
        gpui_kit::init(cx);
        if let Err(error) = assets::load_fonts(cx) {
            eprintln!("Could not load bundled fonts: {error:#}");
        }
        cx.set_global(prefs::Store::load(options.fixture.is_none()));
        let appearance = prefs::get(cx).appearance;
        theme::apply(appearance, cx.window_appearance(), cx);

        let store = cx.new(|cx| QuotaStore::new(client, clock, offset, cx));
        app::init(store.clone(), cx);
        if options.fixture.is_none() && !options.demo {
            let host = store.read(cx).host();
            let saved = prefs::get(cx).sharing.clone();
            cx.background_spawn(sharing::restore(host, saved)).detach();
        }
        // A fixture is a still picture; it should not raise alerts.
        if options.fixture.is_none() {
            cx.observe(&store, |store, cx| {
                if let Some(overview) = store.read(cx).overview.clone() {
                    notifier::check(&overview, cx);
                }
            })
            .detach();
        }

        let (events, mut received) = futures::channel::mpsc::unbounded();
        let tray = match Tray::start(events, &runtime) {
            Ok(tray) => Some(tray),
            Err(error) => {
                eprintln!("Tray unavailable ({error:#}); opening the settings window.");
                None
            }
        };
        let has_tray = tray.is_some();
        if let Some(tray) = tray {
            // Settings changes rebuild the store, so this also follows preferences.
            sync_tray(&tray, &store, cx);
            cx.observe(&store, move |store, cx| sync_tray(&tray, &store, cx))
                .detach();
        }
        cx.spawn(async move |cx| {
            while let Some(event) = received.next().await {
                cx.update(|cx| match event {
                    TrayEvent::Activate(position) => app::toggle_menu(
                        position.map(|(x, y)| point(px(x as f32), px(y as f32))),
                        cx,
                    ),
                    TrayEvent::OpenSettings => app::open_settings(cx),
                    TrayEvent::Refresh => app::refresh(cx),
                    TrayEvent::Quit => app::quit(cx),
                });
            }
        })
        .detach();

        if options.show_settings || !has_tray {
            app::open_settings(cx);
        }
        // Without a tray nothing could reopen or quit a windowless app.
        if !has_tray {
            cx.on_window_closed(|cx, _| {
                if cx.windows().is_empty() {
                    app::quit(cx);
                }
            })
            .detach();
        }
        if options.show_menu {
            app::toggle_menu(None, cx);
        }
    });
    drop(host);
    drop(tray_runtime);
    Ok(())
}

/// Show the quotas and the tray preferences in the tray.
fn sync_tray(tray: &Tray, store: &Entity<QuotaStore>, cx: &mut App) {
    let prefs = prefs::get(cx);
    let overview = store.read(cx).overview.as_ref();
    let used = prefs.quota_display == prefs::QuotaDisplay::Used;
    if let Some(overview) = overview {
        let style = tray::icon::Style {
            used,
            monochrome: prefs.tray_icon == prefs::TrayIcon::Monochrome,
        };
        let gauge = tray::icon::gauge(overview.lowest_remaining(), style);
        tray.update(gauge, tooltip(overview, prefs.hide_names, used));
    }
    #[cfg(target_os = "macos")]
    {
        tray.menu_bar(overview, prefs);
        // Hiding both the menu bar and the Dock icon would leave no way back in.
        let dock = prefs.menu_bar.show_in_dock || !prefs.menu_bar.show_icon;
        cx.set_activation_policy(if dock {
            gpui_kit::ActivationPolicy::Regular
        } else {
            gpui_kit::ActivationPolicy::Accessory
        });
    }
}

/// One line per account with its overall quota, e.g. `Codex · phutrong.it@gmail.com 18%`.
fn tooltip(overview: &model::Overview, hide_names: bool, used: bool) -> String {
    overview
        .groups
        .iter()
        .flat_map(|group| {
            group.accounts.iter().map(move |account| {
                let level = match &account.issue {
                    Some(issue) => issue.title.clone(),
                    None => account
                        .total
                        .map_or_else(|| "—".to_owned(), |total| tray::percent(total, used)),
                };
                let name = if hide_names {
                    model::mask(&account.name)
                } else {
                    account.name.clone()
                };
                format!("{} · {name} {level}", group.name)
            })
        })
        .collect::<Vec<_>>()
        .join("\n")
}
