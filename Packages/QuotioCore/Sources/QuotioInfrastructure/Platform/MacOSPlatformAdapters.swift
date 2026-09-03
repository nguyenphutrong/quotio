import AppKit
import QuotioApplication
import QuotioDomain
import ServiceManagement

@MainActor
public final class WorkspaceURLOpener: URLOpening {
    public init() {}

    public func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
public final class MacOSPasteboardAdapter: PasteboardWriting {
    public init() {}

    public func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

@MainActor
public final class ServiceManagementLaunchAtLoginAdapter: LaunchAtLoginRegistering {
    public init() {}

    public var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown(SMAppService.mainApp.status.rawValue)
        }
    }

    public var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications")
            || path.hasPrefix(NSHomeDirectory() + "/Applications")
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

@MainActor
public final class AppKitUpdaterIconAdapter: UpdaterIconApplying {
    public init() {}

    public func applyUpdateChannel(_ channel: UpdateChannel) {
        let iconName = channel == .beta ? "AppIconBetaImage" : "AppIconImage"
        guard let iconImage = NSImage(named: iconName) else {
            NSApplication.shared.applicationIconImage = nil
            return
        }

        let displaySize = NSSize(width: 256, height: 256)
        let roundedIcon = NSImage(size: displaySize, flipped: false) { rect in
            let path = NSBezierPath(
                roundedRect: rect,
                xRadius: rect.width * 0.22,
                yRadius: rect.height * 0.22
            )
            path.addClip()
            iconImage.draw(in: rect)
            return true
        }
        NSApplication.shared.applicationIconImage = channel == .beta ? roundedIcon : nil
    }
}

@MainActor
public final class AppKitApplicationPlatformAdapter: ApplicationPlatformControlling {
    public init() {}

    public func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    public func setDockVisibility(_ visible: Bool) {
        NSApplication.shared.setActivationPolicy(visible ? .regular : .accessory)
    }

    public func activate() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func terminate() {
        NSApplication.shared.terminate(nil)
    }
}
