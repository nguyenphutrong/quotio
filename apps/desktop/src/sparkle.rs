//! Sparkle owns macOS update UI, validation, whole-bundle replacement and relaunch.
//! Load the packaged framework at runtime so normal Cargo builds need no SDK.
use anyhow::{Context as _, Result, bail};
use objc2::rc::Retained;
use objc2::runtime::{AnyClass, AnyObject, Bool};
use objc2::{AllocAnyThread as _, DefinedClass as _, MainThreadMarker, define_class, msg_send};
use objc2_foundation::{NSBundle, NSObject, NSSet, NSString};

define_class!(
    #[unsafe(super(NSObject))]
    #[name = "QuotioUpdateDelegate"]
    #[ivars = bool]
    struct UpdateDelegate;

    impl UpdateDelegate {
        #[unsafe(method_id(allowedChannelsForUpdater:))]
        fn allowed_channels(&self, _updater: *mut AnyObject) -> Retained<NSSet<NSString>> {
            if *self.ivars() {
                NSSet::from_slice(&[&*NSString::from_str("beta")])
            } else {
                NSSet::new()
            }
        }
    }
);

pub struct Controller {
    controller: Retained<AnyObject>,
    _delegate: Retained<UpdateDelegate>,
    _framework: Retained<NSBundle>,
}

impl Controller {
    pub fn load(automatic: bool) -> Result<Self> {
        MainThreadMarker::new().context("Sparkle must start on the main thread")?;
        let bundle = NSBundle::mainBundle();
        let path = bundle
            .privateFrameworksPath()
            .context("This build has no bundled Sparkle framework")?;
        let path = NSString::from_str(&format!("{path}/Sparkle.framework"));
        let framework = NSBundle::bundleWithPath(&path)
            .context("This build has no bundled Sparkle framework")?;
        // SAFETY: loads the bundled framework signed as part of this application.
        unsafe { framework.loadAndReturnError() }.context("Could not load Sparkle")?;
        let class = AnyClass::get(c"SPUStandardUpdaterController")
            .context("Sparkle controller is unavailable")?;
        let beta = bundle
            .objectForInfoDictionaryKey(&NSString::from_str("QuotioUpdateChannel"))
            .and_then(|value| value.downcast::<NSString>().ok())
            .is_some_and(|value| value.to_string() == "beta");
        let allocated = UpdateDelegate::alloc().set_ivars(beta);
        let delegate: Retained<UpdateDelegate> = unsafe { msg_send![super(allocated), init] };
        // SAFETY: Sparkle 2.8.1's public Objective-C API, called on the main thread.
        // Retained ownership keeps both the controller and its framework alive.
        let allocated: objc2::rc::Allocated<AnyObject> = unsafe { msg_send![class, alloc] };
        let controller: Retained<AnyObject> = unsafe {
            msg_send![
                allocated,
                initWithStartingUpdater: false,
                updaterDelegate: &*delegate,
                userDriverDelegate: std::ptr::null_mut::<AnyObject>()
            ]
        };
        let this = Self {
            controller,
            _delegate: delegate,
            _framework: framework,
        };
        this.automatic(automatic);
        unsafe {
            let updater: Retained<AnyObject> = msg_send![&*this.controller, updater];
            let _: () = msg_send![&*updater, setAutomaticallyDownloadsUpdates: false];
            let mut error: *mut AnyObject = std::ptr::null_mut();
            let started: Bool = msg_send![&*updater, startUpdater: &mut error];
            if !started.as_bool() {
                bail!("Sparkle could not start; check the bundle’s feed URL and public key");
            }
        }
        Ok(this)
    }

    pub fn automatic(&self, automatic: bool) {
        // SAFETY: the retained Sparkle controller owns this SPUUpdater instance.
        unsafe {
            let updater: Retained<AnyObject> = msg_send![&*self.controller, updater];
            let _: () = msg_send![&*updater, setAutomaticallyChecksForUpdates: automatic];
        }
    }

    pub fn check(&self) {
        // Sparkle presents its own interactive progress/error/update window.
        unsafe {
            let _: () =
                msg_send![&*self.controller, checkForUpdates: std::ptr::null_mut::<AnyObject>()];
        }
    }
}

pub fn version() -> Option<String> {
    NSBundle::mainBundle()
        .objectForInfoDictionaryKey(&NSString::from_str("CFBundleShortVersionString"))?
        .downcast::<NSString>()
        .ok()
        .map(|version| version.to_string())
}
