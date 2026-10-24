//! Menu bar status item details tray-icon leaves to the app: Menu Bar preferences and
//! the pinned quotas, drawn as one image like the Swift app's `StatusBarQuotaView`.
use block2::RcBlock;
use objc2::AllocAnyThread as _;
use objc2::MainThreadMarker;
use objc2::rc::Retained;
use objc2::runtime::{AnyObject, Bool};
use objc2_app_kit::{
    NSApplication, NSAttributedStringNSStringDrawing as _, NSAutoresizingMaskOptions, NSColor,
    NSCompositingOperation, NSFont, NSFontAttributeName, NSFontWeightMedium, NSFontWeightSemibold,
    NSForegroundColorAttributeName, NSImage, NSRectFillUsingOperation,
};
use objc2_foundation::{
    NSAttributedString, NSData, NSDictionary, NSPoint, NSRect, NSSize, NSString,
};

use super::{Item, Tray, item};
use crate::model::{Overview, Tone};
use crate::prefs::{Prefs, QuotaDisplay, TrayIcon};

/// Height of the Swift app's quota image.
const HEIGHT: f64 = 22.;
const LOGO: f64 = 14.;

impl Tray {
    /// Shows or hides the status item and draws its content per the Menu Bar
    /// preferences. Runs after `update`, whose gauge it resizes or replaces.
    pub fn menu_bar(&self, overview: Option<&Overview>, prefs: &Prefs) {
        let menu_bar = &prefs.menu_bar;
        let _ = self.icon.set_visible(menu_bar.show_icon);
        let mtm = MainThreadMarker::new().expect("GPUI runs on the main thread");
        let Some(button) = self.icon.ns_status_item().and_then(|item| item.button(mtm)) else {
            return;
        };
        let monochrome = prefs.tray_icon == TrayIcon::Monochrome;
        let used = prefs.quota_display == QuotaDisplay::Used;
        let items: Vec<_> = match overview {
            Some(overview) if menu_bar.show_quota => overview
                .menu_bar_accounts(menu_bar)
                .into_iter()
                .map(|(_, account)| {
                    let logo = logo(&account.provider_id);
                    (logo, item(account, menu_bar.stack_paired, used))
                })
                .collect(),
            _ => Vec::new(),
        };
        // As in Swift, pinned quotas replace the icon rather than sit beside it.
        if items.is_empty() {
            if let Some(gauge) = button.image() {
                gauge.setSize(NSSize::new(16., 16.));
                gauge.setTemplate(monochrome);
                button.setImage(Some(&gauge));
            }
        } else {
            button.setImage(Some(&quota_image(&items, monochrome)));
        }
        // tray-icon catches clicks in a subview sized to the button when it last set
        // the icon; keep it covering the button as the content changes width.
        for view in button.subviews() {
            view.setFrame(button.bounds());
            view.setAutoresizingMask(
                NSAutoresizingMaskOptions::ViewWidthSizable
                    | NSAutoresizingMaskOptions::ViewHeightSizable,
            );
        }
    }
}

/// Lays the items out left to right with Swift's spacing and fonts. Monochrome draws
/// a template, which the menu bar tints for its appearance.
fn quota_image(items: &[(Option<Retained<NSImage>>, Item)], monochrome: bool) -> Retained<NSImage> {
    let dot_font = NSFont::systemFontOfSize(9.);
    // SAFETY: AppKit's font weight constants.
    let (single, stacked) = unsafe {
        (
            NSFont::monospacedSystemFontOfSize_weight(11., NSFontWeightMedium),
            NSFont::monospacedSystemFontOfSize_weight(8.5, NSFontWeightSemibold),
        )
    };
    let mut runs = Vec::new();
    let mut logos = Vec::new();
    let mut x = 4.;
    for (logo, item) in items {
        // Swift shows the provider's 14 pt menu bar glyph; a dot stands in without one.
        if let Some(logo) = logo {
            let rect = NSRect::new(
                NSPoint::new(x, (HEIGHT - LOGO) / 2.),
                NSSize::new(LOGO, LOGO),
            );
            logos.push((logo.clone(), rect));
            x += LOGO + 2.;
        } else {
            let dot = text("●", &dot_font, item.dot, monochrome);
            let size = dot.size();
            runs.push((dot, NSPoint::new(x, (HEIGHT - size.height) / 2.)));
            x += size.width + 2.;
        }
        let font = if item.lines.len() == 2 {
            &stacked
        } else {
            &single
        };
        let lines: Vec<_> = item
            .lines
            .iter()
            .map(|(value, tone)| text(value, font, *tone, monochrome))
            .collect();
        let width = lines.iter().map(|l| l.size().width).fold(0., f64::max);
        let mut y = (HEIGHT - lines.iter().map(|l| l.size().height).sum::<f64>()) / 2.;
        for line in lines {
            let size = line.size();
            // Trailing-aligned, as Swift's stacked pair.
            runs.push((line, NSPoint::new(x + width - size.width, y)));
            y += size.height;
        }
        x += width + 8.;
    }
    let draw = RcBlock::new(move |_: NSRect| {
        for (logo, rect) in &logos {
            logo.drawInRect(*rect);
            // Tint the black artwork with the menu bar's text color, like a template.
            NSColor::labelColor().set();
            NSRectFillUsingOperation(*rect, NSCompositingOperation::SourceAtop);
        }
        for (text, at) in &runs {
            text.drawAtPoint(*at);
        }
        Bool::YES
    });
    let image = NSImage::imageWithSize_flipped_drawingHandler(
        NSSize::new(x - 8. + 4., HEIGHT),
        true,
        &draw,
    );
    image.setTemplate(monochrome);
    image
}

/// The provider's single-color SVG logo, or `None` when there is no artwork or the
/// system can't read SVG.
fn logo(provider_id: &str) -> Option<Retained<NSImage>> {
    let file = crate::assets::AppFiles::get(&crate::providers::logo_path(provider_id)?)?;
    NSImage::initWithData(NSImage::alloc(), &NSData::with_bytes(&file.data))
}

fn text(value: &str, font: &NSFont, tone: Tone, monochrome: bool) -> Retained<NSAttributedString> {
    // Dynamic system colors, resolved against the menu bar's appearance at draw time.
    let color = match tone {
        _ if monochrome => NSColor::blackColor(),
        Tone::Good => NSColor::systemGreenColor(),
        Tone::Warning => NSColor::systemOrangeColor(),
        Tone::Critical => NSColor::systemRedColor(),
        Tone::Neutral => NSColor::labelColor(),
    };
    let values: [&AnyObject; 2] = [font.as_ref(), color.as_ref()];
    // SAFETY: AppKit's attribute keys, with values of the types they expect.
    unsafe {
        let attributes = NSDictionary::from_slices(
            &[NSFontAttributeName, NSForegroundColorAttributeName],
            &values,
        );
        NSAttributedString::new_with_attributes(&NSString::from_str(value), &attributes)
    }
}

/// tray-icon scales the status item's frame to physical pixels; GPUI wants it back in
/// points, measured as tray-icon does from the top left of the primary display.
pub(super) fn logical(x: f64, y: f64) -> (f64, f64) {
    let scale = MainThreadMarker::new()
        .and_then(|mtm| {
            NSApplication::sharedApplication(mtm)
                .currentEvent()?
                .window(mtm)
        })
        .map_or(1., |window| window.backingScaleFactor());
    (x / scale, y / scale)
}
