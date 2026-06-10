//
//  SharedDesktopUIScreen.swift
//  Quotio
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum SharedDesktopUIFeature {
    static let userDefaultsKey = "sharedDesktopUIEnabled"

    static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["QUOTIO_DISABLE_SHARED_UI"] == "1" {
            return false
        }
        if environment["QUOTIO_ENABLE_SHARED_UI"] == "1" {
            return true
        }
        if let persistedOverride = UserDefaults.standard.object(forKey: userDefaultsKey) as? Bool {
            return persistedOverride
        }

        return true
    }
}

struct SharedDesktopUIScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var languageManager = LanguageManager.shared
    @State private var appearanceManager = AppearanceManager.shared
    @State private var modeManager = OperatingModeManager.shared

    var body: some View {
        WebViewHost(
            source: WebViewSource.resolve(),
            bootstrap: WebViewBootstrap(
                locale: languageManager.currentLanguage.rawValue,
                appearance: appearanceManager.appearanceMode.rawValue,
                operatingMode: modeManager.currentMode,
                serverListen: "127.0.0.1:" + String(viewModel.proxyManager.port)
            ),
            viewModel: viewModel
        )
        .navigationTitle(AppRuntimeIdentity.displayName)
        .id(
            languageManager.currentLanguage.rawValue
                + appearanceManager.appearanceMode.rawValue
                + modeManager.currentMode.rawValue
        )
    }
}

struct WebViewBootstrap {
    let locale: String
    let appearance: String
    let operatingMode: OperatingMode
    let serverListen: String
}

enum WebViewSource {
    case devServer(URL)
    case bundled(URL)

    static func resolve(bundle: Bundle = .main) -> WebViewSource? {
        let rawDevServer = ProcessInfo.processInfo.environment["QUOTIO_DESKTOP_UI_DEV_SERVER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawDevServer.isEmpty, let url = URL(string: rawDevServer) {
            return .devServer(url)
        }

        if let indexURL = bundle.url(
            forResource: "desktop-ui/index",
            withExtension: "html"
        ) {
            return .bundled(indexURL)
        }

        return nil
    }
}

private enum DesktopBridgeContract {
    static let version = quotioContractVersion

    enum RequestKind {
        static let runtimeStatus = QuotioRequestKind.RuntimeStatus.rawValue
        static let runtimeStart = QuotioRequestKind.RuntimeStart.rawValue
        static let runtimeStop = QuotioRequestKind.RuntimeStop.rawValue
        static let runtimeRestart = QuotioRequestKind.RuntimeRestart.rawValue
        static let managementRequest = QuotioRequestKind.ManagementRequest.rawValue
        static let nativePreferencesRead = "native.preferencesRead"
        static let nativePreferencesWrite = "native.preferencesWrite"
        static let nativeUpdatesCheck = "native.updatesCheck"
        static let nativeConfirm = QuotioRequestKind.NativeConfirm.rawValue
        static let nativeNotify = QuotioRequestKind.NativeNotify.rawValue
        static let nativeOpenExternal = QuotioRequestKind.NativeOpenExternal.rawValue
        static let nativeOpenTextFile = QuotioRequestKind.NativeOpenTextFile.rawValue
        static let nativeCredentialRead = QuotioRequestKind.NativeCredentialRead.rawValue
        static let nativeCredentialWrite = QuotioRequestKind.NativeCredentialWrite.rawValue
        static let nativeCredentialDelete = QuotioRequestKind.NativeCredentialDelete.rawValue
    }
}

struct WebViewHost: NSViewRepresentable {
    let source: WebViewSource?
    let bootstrap: WebViewBootstrap
    let viewModel: QuotaViewModel

    func makeCoordinator() -> BridgeCoordinator {
        BridgeCoordinator(viewModel: viewModel, bootstrap: bootstrap)
    }

    func makeNSView(context: Context) -> NSView {
        guard let source else {
            return NSHostingView(rootView: SharedDesktopUIUnavailableView())
        }

        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: BridgeCoordinator.messageName)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: context.coordinator.bootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false

        switch source {
        case .devServer(let url):
            webView.load(URLRequest(url: url))
        case .bundled(let url):
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        context.coordinator.attach(webView)
        return webView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(bootstrap: bootstrap)
    }
}

struct SharedDesktopUIUnavailableView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("sharedUI.unavailable.title".localized())
                .font(.headline)
            Text("sharedUI.unavailable.description".localized())
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

@MainActor
final class BridgeCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let messageName = "quotioBridge"

    private weak var webView: WKWebView?
    private weak var viewModel: QuotaViewModel?
    private var bootstrap: WebViewBootstrap
    private let macAgentAdapter = MacAgentBridgeAdapter()

    init(viewModel: QuotaViewModel, bootstrap: WebViewBootstrap) {
        self.viewModel = viewModel
        self.bootstrap = bootstrap
    }

    var bootstrapScript: String {
        """
        (() => {
          const bootstrap = \(Self.javascriptObjectLiteral(bootstrapPayload));
          window.__QUOTIO_DESKTOP_BOOTSTRAP__ = bootstrap;
          window.__QUOTIO_DESKTOP_BRIDGE__ = {
            runtimeStatus: () => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                id,
                kind: '\(DesktopBridgeContract.RequestKind.runtimeStatus)'
              });
            }),
            runtimeStart: () => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                id,
                kind: '\(DesktopBridgeContract.RequestKind.runtimeStart)'
              });
            }),
            runtimeStop: () => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                id,
                kind: '\(DesktopBridgeContract.RequestKind.runtimeStop)'
              });
            }),
            runtimeRestart: () => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                id,
                kind: '\(DesktopBridgeContract.RequestKind.runtimeRestart)'
              });
            }),
            preferencesRead: () => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                id,
                kind: '\(DesktopBridgeContract.RequestKind.nativePreferencesRead)'
              });
            }),
            preferencesWrite: (request) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                id,
                kind: '\(DesktopBridgeContract.RequestKind.nativePreferencesWrite)',
                preferences: request?.preferences || {}
              });
            }),
            updatesCheck: () => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                id,
                kind: '\(DesktopBridgeContract.RequestKind.nativeUpdatesCheck)'
              });
            }),
            request: (request) => new Promise((resolve, reject) => {
              const id = request?.id || crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                id,
                kind: '\(DesktopBridgeContract.RequestKind.managementRequest)',
                path: request?.path,
                init: request?.init || {}
              });
            }),
            confirm: (request) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                id,
                kind: '\(DesktopBridgeContract.RequestKind.nativeConfirm)',
                title: request?.title,
                message: request?.message,
                confirmLabel: request?.confirmLabel,
                cancelLabel: request?.cancelLabel,
                destructive: request?.destructive === true
              });
            }),
            notify: (request) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                id,
                kind: '\(DesktopBridgeContract.RequestKind.nativeNotify)',
                title: request?.title,
                message: request?.message,
                tone: request?.tone
              });
            }),
            openExternal: (url) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                id,
                kind: '\(DesktopBridgeContract.RequestKind.nativeOpenExternal)',
                url
              });
            }),
            openTextFile: (request) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                id,
                kind: '\(DesktopBridgeContract.RequestKind.nativeOpenTextFile)',
                title: request?.title,
                allowedExtensions: request?.allowedExtensions || []
              });
            }),
            credentialRead: (request) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                id,
                kind: '\(DesktopBridgeContract.RequestKind.nativeCredentialRead)',
                targetName: request?.targetName
              });
            }),
            credentialWrite: (request) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                id,
                kind: '\(DesktopBridgeContract.RequestKind.nativeCredentialWrite)',
                targetName: request?.targetName,
                value: request?.value
              });
            }),
            credentialDelete: (request) => new Promise((resolve, reject) => {
              const id = crypto.randomUUID();
              window.__QUOTIO_BRIDGE_CALLBACKS__ = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
              window.__QUOTIO_BRIDGE_CALLBACKS__[id] = { resolve, reject };
              window.webkit.messageHandlers.\(Self.messageName).postMessage({
                id,
                kind: '\(DesktopBridgeContract.RequestKind.nativeCredentialDelete)',
                targetName: request?.targetName
              });
            })
          };
          window.__QUOTIO_DESKTOP_BRIDGE_RECEIVE__ = (message) => {
            const callbacks = window.__QUOTIO_BRIDGE_CALLBACKS__ || {};
            const callback = callbacks[message.id];
            if (!callback) return;
            delete callbacks[message.id];
            if (message.ok) {
              callback.resolve(message.value);
            } else {
              callback.reject(new Error(message.error || 'Desktop bridge request failed'));
            }
          };
        })();
        """
    }

    private var bootstrapPayload: [String: Any] {
        return [
            "uiEnabled": true,
            "basePath": "/",
            "bridgeVersion": DesktopBridgeContract.version,
            "serverListen": bootstrap.serverListen,
            "platform": "macos",
            "operatingMode": bootstrap.operatingMode.rawValue,
            "locale": bootstrap.locale,
            "appearance": bootstrap.appearance,
            "features": [
                "overview": true,
                "providers": true,
                "quota": true,
                "usage": true,
                "virtualModels": true,
                "models": true,
                "agents": bootstrap.operatingMode.supportsAgentConfig,
                "apiKeys": true,
                "logs": true,
                "settings": true,
                "about": true
            ],
            "capabilities": [
                "supportsLocalProxy": true,
                "supportsProxyControl": bootstrap.operatingMode.supportsProxyControl,
                "supportsPortConfig": bootstrap.operatingMode.supportsPortConfig,
                "supportsCliOAuth": bootstrap.operatingMode.supportsCLIBasedOAuth,
                "supportsAgentConfig": bootstrap.operatingMode.supportsAgentConfig,
                "supportsRemoteConnections": true,
                "supportsCredentialStorage": true,
                "supportsManagementBridge": true,
                "supportsNativeOnboarding": true,
                "supportsNativePreferences": true,
                "supportsTrayBehavior": false,
                "supportsAppearanceSync": true,
                "supportsRequestLogSettings": true,
                "supportsModelSettings": true,
                "supportsApiKeyManagement": true,
                "supportsVirtualModelManagement": true,
                "supportsUpdates": AppRuntimeIdentity.updatesEnabled
            ]
        ]
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func update(bootstrap: WebViewBootstrap) {
        guard self.bootstrap.locale != bootstrap.locale
            || self.bootstrap.appearance != bootstrap.appearance
            || self.bootstrap.operatingMode != bootstrap.operatingMode
            || self.bootstrap.serverListen != bootstrap.serverListen else {
            return
        }
        self.bootstrap = bootstrap
        evaluate(script: "window.__QUOTIO_DESKTOP_BOOTSTRAP__ = \(Self.javascriptObjectLiteral(bootstrapPayload));")
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            handle(message: message)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }

        if url.isFileURL || url.host == "localhost" || url.host == "127.0.0.1" {
            return .allow
        }

        if navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    private func handle(message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let kind = body["kind"] as? String else {
            return
        }

        let start = Date()
        Task { @MainActor in
            do {
                let value: Any
                switch kind {
                case DesktopBridgeContract.RequestKind.runtimeStatus:
                    value = try handleRuntimeStatus()
                case DesktopBridgeContract.RequestKind.runtimeStart:
                    value = try await handleRuntimeStart()
                case DesktopBridgeContract.RequestKind.runtimeStop:
                    value = try handleRuntimeStop()
                case DesktopBridgeContract.RequestKind.runtimeRestart:
                    value = try await handleRuntimeRestart()
                case DesktopBridgeContract.RequestKind.nativePreferencesRead:
                    value = handleNativePreferencesRead()
                case DesktopBridgeContract.RequestKind.nativePreferencesWrite:
                    value = try handleNativePreferencesWrite(body)
                case DesktopBridgeContract.RequestKind.nativeUpdatesCheck:
                    value = handleNativeUpdatesCheck()
                case DesktopBridgeContract.RequestKind.managementRequest:
                    value = try await handleManagementRequest(body)
                case DesktopBridgeContract.RequestKind.nativeConfirm:
                    value = handleNativeConfirm(body)
                case DesktopBridgeContract.RequestKind.nativeNotify:
                    value = handleNativeNotify(body)
                case DesktopBridgeContract.RequestKind.nativeOpenExternal:
                    value = try handleNativeOpenExternal(body)
                case DesktopBridgeContract.RequestKind.nativeOpenTextFile:
                    value = try handleNativeOpenTextFile(body) ?? NSNull()
                case DesktopBridgeContract.RequestKind.nativeCredentialRead:
                    value = try handleNativeCredentialRead(body)
                case DesktopBridgeContract.RequestKind.nativeCredentialWrite:
                    value = try handleNativeCredentialWrite(body)
                case DesktopBridgeContract.RequestKind.nativeCredentialDelete:
                    value = try handleNativeCredentialDelete(body)
                default:
                    throw APIError.invalidURL
                }
                let duration = Date().timeIntervalSince(start)
                Log.debug("[Bridge] \(id) \(kind) ok duration=\(String(format: "%.3f", duration))s")
                sendResponse(id: id, ok: true, value: value, error: nil)
            } catch {
                let duration = Date().timeIntervalSince(start)
                Log.warning("[Bridge] \(id) \(kind) failed duration=\(String(format: "%.3f", duration))s error=\(error.localizedDescription)")
                sendResponse(id: id, ok: false, value: NSNull(), error: error.localizedDescription)
            }
        }
    }

    private func handleRuntimeStatus() throws -> [String: Any] {
        guard let viewModel else {
            throw APIError.connectionError("Desktop bridge is unavailable")
        }

        return runtimeStatusPayload(viewModel: viewModel)
    }

    private func handleRuntimeStart() async throws -> [String: Any] {
        guard let viewModel else {
            throw APIError.connectionError("Desktop bridge is unavailable")
        }

        await viewModel.startProxy()
        return runtimeStatusPayload(viewModel: viewModel)
    }

    private func handleRuntimeStop() throws -> [String: Any] {
        guard let viewModel else {
            throw APIError.connectionError("Desktop bridge is unavailable")
        }

        viewModel.stopProxy()
        return runtimeStatusPayload(viewModel: viewModel)
    }

    private func handleRuntimeRestart() async throws -> [String: Any] {
        guard let viewModel else {
            throw APIError.connectionError("Desktop bridge is unavailable")
        }

        await viewModel.restartProxy()
        return runtimeStatusPayload(viewModel: viewModel)
    }

    private func runtimeStatusPayload(viewModel: QuotaViewModel) -> [String: Any] {
        if viewModel.proxyManager.proxyStatus.running {
            return [
                "state": "managed",
                "endpoint": viewModel.proxyManager.clientEndpoint + "/v1"
            ]
        }

        return [
            "state": "stopped",
            "endpoint": NSNull()
        ]
    }

    private func handleNativePreferencesRead() -> [String: Any] {
        LaunchAtLoginManager.shared.refreshStatus()
        return nativePreferencesPayload()
    }

    private func handleNativePreferencesWrite(_ body: [String: Any]) throws -> [String: Any] {
        guard let preferences = body["preferences"] as? [String: Any] else {
            throw APIError.connectionError("Preferences payload is required")
        }

        if let rawMode = preferences["operatingMode"] as? String,
           let mode = OperatingMode(rawValue: rawMode),
           mode != bootstrap.operatingMode {
            guard mode != .remoteProxy || OperatingModeManager.shared.remoteConfig != nil else {
                throw APIError.connectionError("Remote connection must be configured before switching to remote mode")
            }
            OperatingModeManager.shared.switchMode(to: mode) {
                self.viewModel?.stopProxy()
            }
            bootstrap = WebViewBootstrap(
                locale: bootstrap.locale,
                appearance: bootstrap.appearance,
                operatingMode: mode,
                serverListen: bootstrap.serverListen
            )
            Task {
                await viewModel?.initialize()
            }
        }

        if let rawLanguage = preferences["language"] as? String,
           let language = AppLanguage(rawValue: rawLanguage) {
            LanguageManager.shared.setLanguage(language)
            bootstrap = WebViewBootstrap(
                locale: language.rawValue,
                appearance: bootstrap.appearance,
                operatingMode: bootstrap.operatingMode,
                serverListen: bootstrap.serverListen
            )
        }

        if let rawAppearance = preferences["appearance"] as? String,
           let appearance = AppearanceMode(rawValue: rawAppearance) {
            AppearanceManager.shared.appearanceMode = appearance
            bootstrap = WebViewBootstrap(
                locale: bootstrap.locale,
                appearance: appearance.rawValue,
                operatingMode: bootstrap.operatingMode,
                serverListen: bootstrap.serverListen
            )
        }

        if let launchAtLogin = preferences["launchAtLogin"] as? Bool {
            try LaunchAtLoginManager.shared.setEnabled(launchAtLogin)
        }

        if let proxyPort = preferences["proxyPort"] as? Int {
            guard proxyPort > 0 && proxyPort < 65536 else {
                throw APIError.connectionError("Proxy port must be between 1 and 65535")
            }
            viewModel?.proxyManager.port = UInt16(proxyPort)
        } else if let proxyPort = preferences["proxyPort"] as? Double {
            let port = Int(proxyPort)
            guard port > 0 && port < 65536 else {
                throw APIError.connectionError("Proxy port must be between 1 and 65535")
            }
            viewModel?.proxyManager.port = UInt16(port)
        }

        if let allowNetworkAccess = preferences["allowNetworkAccess"] as? Bool {
            viewModel?.proxyManager.allowNetworkAccess = allowNetworkAccess
        }

        if let autoStartTunnel = preferences["autoStartTunnel"] as? Bool {
            UserDefaults.standard.set(autoStartTunnel, forKey: "autoStartTunnel")
        }

        if let autoRestartTunnel = preferences["autoRestartTunnel"] as? Bool {
            UserDefaults.standard.set(autoRestartTunnel, forKey: "autoRestartTunnel")
        }

        if let authDir = preferences["authDir"] as? String {
            try viewModel?.proxyManager.setAuthDir(authDir)
        }

        let notificationManager = NotificationManager.shared
        if let notificationsEnabled = preferences["notificationsEnabled"] as? Bool {
            notificationManager.notificationsEnabled = notificationsEnabled
        }
        if let notifyOnQuotaLow = preferences["notifyOnQuotaLow"] as? Bool {
            notificationManager.notifyOnQuotaLow = notifyOnQuotaLow
        }
        if let notifyOnCooling = preferences["notifyOnCooling"] as? Bool {
            notificationManager.notifyOnCooling = notifyOnCooling
        }
        if let notifyOnProxyCrash = preferences["notifyOnProxyCrash"] as? Bool {
            notificationManager.notifyOnProxyCrash = notifyOnProxyCrash
        }
        if let quotaAlertThreshold = preferences["quotaAlertThreshold"] as? Double {
            notificationManager.quotaAlertThreshold = quotaAlertThreshold
        } else if let quotaAlertThreshold = preferences["quotaAlertThreshold"] as? Int {
            notificationManager.quotaAlertThreshold = Double(quotaAlertThreshold)
        }

        let menuBarSettings = MenuBarSettingsManager.shared
        if let rawQuotaDisplayMode = preferences["quotaDisplayMode"] as? String,
           let quotaDisplayMode = QuotaDisplayMode(rawValue: rawQuotaDisplayMode) {
            menuBarSettings.quotaDisplayMode = quotaDisplayMode
        }
        if let rawQuotaDisplayStyle = preferences["quotaDisplayStyle"] as? String,
           let quotaDisplayStyle = QuotaDisplayStyle(rawValue: rawQuotaDisplayStyle) {
            menuBarSettings.quotaDisplayStyle = quotaDisplayStyle
        }
        if let rawResetTimeDisplayMode = preferences["resetTimeDisplayMode"] as? String,
           let resetTimeDisplayMode = ResetTimeDisplayMode(rawValue: rawResetTimeDisplayMode) {
            menuBarSettings.resetTimeDisplayMode = resetTimeDisplayMode
        }
        if let rawRefreshCadence = preferences["refreshCadence"] as? String,
           let refreshCadence = RefreshCadence(rawValue: rawRefreshCadence) {
            RefreshSettingsManager.shared.refreshCadence = refreshCadence
        }

        var showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        if let incomingShowInDock = preferences["showInDock"] as? Bool {
            showInDock = incomingShowInDock
        }
        var showMenuBarIcon = menuBarSettings.showMenuBarIcon
        if let incomingShowMenuBarIcon = preferences["showMenuBarIcon"] as? Bool {
            showMenuBarIcon = incomingShowMenuBarIcon
        }
        if !showInDock && !showMenuBarIcon {
            showMenuBarIcon = true
        }
        UserDefaults.standard.set(showInDock, forKey: "showInDock")
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        menuBarSettings.showMenuBarIcon = showMenuBarIcon

        if let showQuotaInMenuBar = preferences["showQuotaInMenuBar"] as? Bool {
            menuBarSettings.showQuotaInMenuBar = showQuotaInMenuBar
        }
        if let menuBarMaxItems = preferences["menuBarMaxItems"] as? Int {
            menuBarSettings.menuBarMaxItems = Self.clampedMenuBarMaxItems(menuBarMaxItems)
            viewModel?.syncMenuBarSelection()
        } else if let menuBarMaxItems = preferences["menuBarMaxItems"] as? Double {
            menuBarSettings.menuBarMaxItems = Self.clampedMenuBarMaxItems(Int(menuBarMaxItems))
            viewModel?.syncMenuBarSelection()
        }
        if let rawColorMode = preferences["menuBarColorMode"] as? String,
           let colorMode = MenuBarColorMode(rawValue: rawColorMode) {
            menuBarSettings.colorMode = colorMode
        }
        if let hideSensitiveInfo = preferences["hideSensitiveInfo"] as? Bool {
            menuBarSettings.hideSensitiveInfo = hideSensitiveInfo
        }
        if let rawTotalUsageMode = preferences["totalUsageMode"] as? String,
           let totalUsageMode = TotalUsageMode(rawValue: rawTotalUsageMode) {
            menuBarSettings.totalUsageMode = totalUsageMode
        }
        if let rawModelAggregationMode = preferences["modelAggregationMode"] as? String,
           let modelAggregationMode = ModelAggregationMode(rawValue: rawModelAggregationMode) {
            menuBarSettings.modelAggregationMode = modelAggregationMode
        }

        if let autoCheckUpdates = preferences["autoCheckUpdates"] as? Bool {
            UserDefaults.standard.set(autoCheckUpdates, forKey: "autoCheckUpdates")
            UpdaterService.shared.initializeIfNeeded()
            UpdaterService.shared.automaticallyChecksForUpdates = autoCheckUpdates
        }
        if let rawUpdateChannel = preferences["updateChannel"] as? String,
           let updateChannel = UpdateChannel(rawValue: rawUpdateChannel) {
            UpdaterService.shared.updateChannel = AppRuntimeIdentity.isBeta ? .beta : updateChannel
        }

        evaluate(script: "window.__QUOTIO_DESKTOP_BOOTSTRAP__ = \(Self.javascriptObjectLiteral(bootstrapPayload));")
        return nativePreferencesPayload()
    }

    private func nativePreferencesPayload() -> [String: Any] {
        let notificationManager = NotificationManager.shared
        let menuBarSettings = MenuBarSettingsManager.shared
        let showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        let proxyManager = viewModel?.proxyManager
        let updaterService = UpdaterService.shared
        let autoCheckUpdates = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool
            ?? updaterService.automaticallyChecksForUpdates
        let lastUpdateCheckAt: Any
        if let lastUpdateCheckDate = updaterService.lastUpdateCheckDate {
            lastUpdateCheckAt = ISO8601DateFormatter().string(from: lastUpdateCheckDate)
        } else {
            lastUpdateCheckAt = NSNull()
        }

        return [
            "operatingMode": OperatingModeManager.shared.currentMode.rawValue,
            "remoteConfigured": OperatingModeManager.shared.remoteConfig != nil,
            "language": LanguageManager.shared.currentLanguage.rawValue,
            "appearance": AppearanceManager.shared.appearanceMode.rawValue,
            "launchAtLogin": LaunchAtLoginManager.shared.isEnabled,
            "launchAtLoginCanOpenSystemSettings": true,
            "proxyPort": Int(proxyManager?.port ?? 0),
            "proxyEndpoint": proxyManager?.proxyStatus.endpoint ?? "",
            "proxyRunning": proxyManager?.proxyStatus.running ?? false,
            "proxyServerKind": OperatingModeManager.shared.serverInfo?.kind.rawValue ?? "cpa-plusplus",
            "proxyServerVersion": OperatingModeManager.shared.serverInfo?.version ?? proxyManager?.currentVersion ?? NSNull(),
            "proxyInstallStatus": Self.proxyInstallStatus(proxyManager),
            "proxyActiveBinaryPath": proxyManager?.activeBinaryPathDescription ?? "",
            "proxyConfigPath": proxyManager?.configPath ?? "",
            "allowNetworkAccess": proxyManager?.allowNetworkAccess ?? false,
            "autoStartTunnel": UserDefaults.standard.bool(forKey: "autoStartTunnel"),
            "autoRestartTunnel": UserDefaults.standard.bool(forKey: "autoRestartTunnel"),
            "tunnelInstalled": viewModel?.tunnelManager.installation.isInstalled ?? false,
            "authDir": proxyManager?.authDir ?? "",
            "defaultAuthDir": proxyManager?.defaultAuthDir ?? "",
            "notificationsEnabled": notificationManager.notificationsEnabled,
            "notifyOnQuotaLow": notificationManager.notifyOnQuotaLow,
            "notifyOnCooling": notificationManager.notifyOnCooling,
            "notifyOnProxyCrash": notificationManager.notifyOnProxyCrash,
            "quotaAlertThreshold": Int(notificationManager.quotaAlertThreshold),
            "quotaDisplayMode": menuBarSettings.quotaDisplayMode.rawValue,
            "quotaDisplayStyle": menuBarSettings.quotaDisplayStyle.rawValue,
            "resetTimeDisplayMode": menuBarSettings.resetTimeDisplayMode.rawValue,
            "refreshCadence": RefreshSettingsManager.shared.refreshCadence.rawValue,
            "showInDock": showInDock,
            "showMenuBarIcon": menuBarSettings.showMenuBarIcon,
            "showQuotaInMenuBar": menuBarSettings.showQuotaInMenuBar,
            "menuBarMaxItems": menuBarSettings.menuBarMaxItems,
            "menuBarColorMode": menuBarSettings.colorMode.rawValue,
            "hideSensitiveInfo": menuBarSettings.hideSensitiveInfo,
            "totalUsageMode": menuBarSettings.totalUsageMode.rawValue,
            "modelAggregationMode": menuBarSettings.modelAggregationMode.rawValue,
            "updatesSupported": AppRuntimeIdentity.updatesEnabled,
            "autoCheckUpdates": autoCheckUpdates,
            "updateChannel": AppRuntimeIdentity.isBeta ? UpdateChannel.beta.rawValue : updaterService.updateChannel.rawValue,
            "updateChannelLocked": AppRuntimeIdentity.isBeta,
            "canCheckForUpdates": updaterService.canCheckForUpdates,
            "isCheckingForUpdates": updaterService.isCheckingForUpdates,
            "lastUpdateCheckAt": lastUpdateCheckAt
        ]
    }

    private func handleNativeUpdatesCheck() -> [String: Any] {
        guard AppRuntimeIdentity.updatesEnabled else {
            return nativePreferencesPayload()
        }

        UpdaterService.shared.checkForUpdates()
        return nativePreferencesPayload()
    }

    private static func clampedMenuBarMaxItems(_ value: Int) -> Int {
        min(max(value, MenuBarSettingsManager.minMenuBarItems), MenuBarSettingsManager.maxMenuBarItems)
    }

    private static func proxyInstallStatus(_ proxyManager: CLIProxyManager?) -> String {
        guard let proxyManager else { return "not-installed" }

        let source = proxyManager.activeBinarySourceDescription
        if source == "Dev override" { return "dev-override" }
        if source == "Bundled" { return "bundled" }
        if proxyManager.hasLegacyCLIProxyAPIInstall {
            return "legacy-compatible"
        }
        return "not-installed"
    }

    private func handleManagementRequest(_ body: [String: Any]) async throws -> Any {
        guard let viewModel else {
            throw APIError.connectionError("Desktop bridge is unavailable")
        }
        guard let path = body["path"] as? String else {
            throw APIError.invalidURL
        }

        let initPayload = body["init"] as? [String: Any] ?? [:]
        let method = initPayload["method"] as? String ?? "GET"
        let bodyString = initPayload["body"] as? String
        let bodyData = bodyString?.data(using: .utf8)

        if path == "/agents" || path.hasPrefix("/agents/") {
            return try await macAgentAdapter.handle(
                path: path,
                method: method,
                proxyURL: viewModel.proxyManager.clientEndpoint + "/v1",
                apiKey: viewModel.proxyManager.managementKey
            )
        }

        let (client, errorMessage) = await viewModel.managementAPIClientForAction(
            bundleMissingMessage: "sharedUI.error.bundleMissing".localized(),
            startLocalMessage: "sharedUI.error.startLocal".localized(),
            remoteDisconnectedMessage: "sharedUI.error.remoteDisconnected".localized(),
            connectMessage: "sharedUI.error.connect".localized()
        )
        guard let client else {
            throw APIError.connectionError(errorMessage ?? "sharedUI.error.connect".localized())
        }

        let data = try await client.bridgeRequest(endpoint: path, method: method, body: bodyData)
        guard !data.isEmpty else { return NSNull() }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func handleNativeConfirm(_ body: [String: Any]) -> Bool {
        let alert = NSAlert()
        alert.messageText = body["title"] as? String ?? "Quotio"
        alert.informativeText = body["message"] as? String ?? ""
        alert.alertStyle = (body["destructive"] as? Bool) == true ? .warning : .informational
        alert.addButton(withTitle: body["confirmLabel"] as? String ?? "OK")
        alert.addButton(withTitle: body["cancelLabel"] as? String ?? "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func handleNativeNotify(_ body: [String: Any]) -> Bool {
        NotificationManager.shared.notifyDesktopFeedback(
            title: body["title"] as? String ?? AppRuntimeIdentity.displayName,
            body: body["message"] as? String ?? "",
            tone: body["tone"] as? String ?? "success"
        )
    }

    private func handleNativeOpenExternal(_ body: [String: Any]) throws -> Bool {
        guard let rawURL = body["url"] as? String,
              let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw APIError.invalidURL
        }

        return NSWorkspace.shared.open(url)
    }

    private func handleNativeOpenTextFile(_ body: [String: Any]) throws -> String? {
        let panel = NSOpenPanel()
        panel.title = body["title"] as? String ?? "Open File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.allowedTextFileTypes(body)

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func allowedTextFileTypes(_ body: [String: Any]) -> [UTType] {
        let extensions = body["allowedExtensions"] as? [String] ?? []
        let types = extensions.compactMap { fileExtension in
            UTType(filenameExtension: fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }

        return types.isEmpty ? [.json, .plainText, .text] : types
    }

    private func handleNativeCredentialRead(_ body: [String: Any]) throws -> [String: Any] {
        let targetName = try readRequiredCredentialTargetName(body)
        let value = KeychainHelper.getDesktopBridgeCredential(targetName: targetName)
        return [
            "targetName": targetName,
            "exists": value != nil,
            "value": value ?? NSNull()
        ]
    }

    private func handleNativeCredentialWrite(_ body: [String: Any]) throws -> Bool {
        let targetName = try readRequiredCredentialTargetName(body)
        let value = body["value"] as? String ?? ""
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.connectionError("Credential value is required")
        }

        guard KeychainHelper.saveDesktopBridgeCredential(value, targetName: targetName) else {
            throw APIError.connectionError("Credential could not be saved")
        }
        return true
    }

    private func handleNativeCredentialDelete(_ body: [String: Any]) throws -> Bool {
        KeychainHelper.deleteDesktopBridgeCredential(targetName: try readRequiredCredentialTargetName(body))
        return true
    }

    private func readRequiredCredentialTargetName(_ body: [String: Any]) throws -> String {
        let targetName = (body["targetName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetName.isEmpty, targetName.hasPrefix("Quotio/") else {
            throw APIError.connectionError("Invalid credential target")
        }

        return targetName
    }

    private func sendResponse(id: String, ok: Bool, value: Any, error: String?) {
        let payload: [String: Any] = [
            "id": id,
            "ok": ok,
            "value": value,
            "error": error ?? NSNull()
        ]
        evaluate(script: "window.__QUOTIO_DESKTOP_BRIDGE_RECEIVE__(\(Self.javascriptObjectLiteral(payload)));")
    }

    private func evaluate(script: String) {
        webView?.evaluateJavaScript(script) { _, error in
            if let error {
                Log.warning("[Bridge] Failed to evaluate script: \(error.localizedDescription)")
            }
        }
    }

    private static func javascriptObjectLiteral(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }
}

private final class MacAgentBridgeAdapter {
    private let detectionService = AgentDetectionService()
    private let configurationService = AgentConfigurationService()
    private let fileManager = FileManager.default

    func handle(path: String, method: String, proxyURL: String, apiKey: String) async throws -> Any {
        let normalizedMethod = method.uppercased()
        let parts = path.split(separator: "/").map(String.init)

        if parts == ["agents"], normalizedMethod == "GET" {
            let statuses = await detectionService.detectAllAgents(forceRefresh: true)
            var agents: [[String: Any]] = []
            for status in statuses {
                agents.append(await descriptor(for: status))
            }
            return ["agents": agents]
        }

        guard parts.count == 3, parts[0] == "agents" else {
            throw APIError.connectionError("Unsupported macOS agents endpoint")
        }
        guard let agent = CLIAgent(rawValue: parts[1]) else {
            throw APIError.connectionError("Unsupported macOS agent")
        }

        switch (parts[2], normalizedMethod) {
        case ("guide", "GET"):
            return await guide(for: agent)
        case ("diff", "POST"):
            return await diff(for: agent, proxyURL: proxyURL, apiKey: apiKey)
        case ("install", "POST"):
            return try await install(agent: agent, proxyURL: proxyURL, apiKey: apiKey)
        case ("rollback", "POST"):
            return try await rollback(agent: agent, proxyURL: proxyURL, apiKey: apiKey)
        default:
            throw APIError.connectionError("Unsupported macOS agents endpoint")
        }
    }

    private func descriptor(for status: AgentStatus) async -> [String: Any] {
        let agent = status.agent
        return jsonObject([
            ("id", agent.id),
            ("label", agent.displayName),
            ("binaries", agent.binaryNames),
            ("config_mode", agent.configType.rawValue),
            ("platform_support", status.platformSupport.rawValue),
            ("support_message", status.message),
            ("rollback_available", await rollbackAvailable(for: agent)),
            ("target_paths", expandedConfigPaths(for: agent)),
            ("docs_url", agent.docsURL?.absoluteString),
            ("capabilities", await capabilities(for: agent)),
            ("caveats", caveats(for: agent))
        ])
    }

    private func guide(for agent: CLIAgent) async -> [String: Any] {
        [
            "guide": jsonObject([
                ("tool", agent.id),
                ("label", agent.displayName),
                ("config_mode", agent.configType.rawValue),
                ("docs_url", agent.docsURL?.absoluteString),
                ("target_paths", expandedConfigPaths(for: agent)),
                ("binaries", agent.binaryNames),
                ("capabilities", await capabilities(for: agent)),
                ("steps", [
                    "Install and verify \(agent.displayName) on macOS.",
                    "Review the generated configuration diff before applying automatic configuration.",
                    "Restart the agent terminal session after install so it uses the Quotio endpoint."
                ]),
                ("verify", agent.binaryNames.map { "\($0) --version" }),
                ("caveats", caveats(for: agent))
            ])
        ]
    }

    private func diff(for agent: CLIAgent, proxyURL: String, apiKey: String) async -> [String: Any] {
        let status = await statusPayload(for: agent)
        let plan = await planPayload(for: agent, proxyURL: proxyURL, apiKey: apiKey, mode: .manual)
        return [
            "status": status,
            "plan": plan,
            "summary": "Review the macOS \(agent.displayName) configuration before applying changes."
        ]
    }

    private func install(agent: CLIAgent, proxyURL: String, apiKey: String) async throws -> [String: Any] {
        guard agent != .geminiCLI else {
            throw APIError.connectionError("Gemini CLI shell profile writes are still handled by the native macOS setup flow.")
        }

        let result = try await configurationResult(for: agent, proxyURL: proxyURL, apiKey: apiKey, mode: .automatic)
        if !result.success {
            throw APIError.connectionError(result.error ?? "Agent install failed")
        }

        await detectionService.markAsConfigured(agent)
        await detectionService.invalidateCache()

        return [
            "status": await statusPayload(for: agent),
            "plan": jsonObject([
                ("tool", agent.id),
                ("home_dir", fileManager.homeDirectoryForCurrentUser.path),
                ("base_url", proxyURL),
                ("backup_dir", backupDirectory(for: agent)),
                ("auth_token", redacted(apiKey))
            ]),
            "manifest": manifest(for: agent, proxyURL: proxyURL, apiKey: apiKey, backupPath: result.backupPath),
            "summary": result.instructions
        ]
    }

    private func rollback(agent: CLIAgent, proxyURL: String, apiKey: String) async throws -> [String: Any] {
        guard let backup = await configurationService.listBackups(agent: agent).first else {
            throw APIError.connectionError("No macOS backup is available for \(agent.displayName)")
        }

        try await configurationService.restoreFromBackup(backup)
        await detectionService.invalidateCache()

        return [
            "status": await statusPayload(for: agent),
            "manifest": manifest(for: agent, proxyURL: proxyURL, apiKey: apiKey, backupPath: backup.path),
            "summary": "Restored \(agent.displayName) from \(backup.displayName)."
        ]
    }

    private func statusPayload(for agent: CLIAgent) async -> [String: Any] {
        let status = await detectionService.detectAgent(agent)
        return jsonObject([
            ("tool", agent.id),
            ("home_dir", fileManager.homeDirectoryForCurrentUser.path),
            ("target_paths", expandedConfigPaths(for: agent)),
            ("installed", status.installed),
            ("configured", status.configured),
            ("platform_support", status.platformSupport.rawValue),
            ("rollback_available", await rollbackAvailable(for: agent)),
            ("binary_path", status.binaryPath),
            ("message", status.message)
        ])
    }

    private func planPayload(
        for agent: CLIAgent,
        proxyURL: String,
        apiKey: String,
        mode: ConfigurationMode
    ) async -> [String: Any] {
        let result = try? await configurationResult(for: agent, proxyURL: proxyURL, apiKey: apiKey, mode: mode)
        let files = (result?.rawConfigs ?? []).map { rawConfig in
            jsonObject([
                ("target_path", rawConfig.targetPath ?? rawConfig.filename ?? agent.id),
                ("existed", rawConfig.targetPath.map { fileManager.fileExists(atPath: $0) } ?? false),
                ("has_changes", true),
                ("before", rawConfig.targetPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }),
                ("after", rawConfig.content)
            ])
        }

        return jsonObject([
            ("tool", agent.id),
            ("home_dir", fileManager.homeDirectoryForCurrentUser.path),
            ("base_url", proxyURL),
            ("backup_dir", backupDirectory(for: agent)),
            ("files", files)
        ])
    }

    private func configurationResult(
        for agent: CLIAgent,
        proxyURL: String,
        apiKey: String,
        mode: ConfigurationMode
    ) async throws -> AgentConfigResult {
        let config = AgentConfiguration(agent: agent, proxyURL: proxyURL, apiKey: apiKey)
        return try await configurationService.generateConfiguration(
            agent: agent,
            config: config,
            mode: mode,
            storageOption: .jsonOnly,
            detectionService: detectionService,
            availableModels: AvailableModel.allModels
        )
    }

    private func manifest(for agent: CLIAgent, proxyURL: String, apiKey: String, backupPath: String?) -> [String: Any] {
        jsonObject([
            ("tool", agent.id),
            ("home_dir", fileManager.homeDirectoryForCurrentUser.path),
            ("backup_dir", backupDirectory(for: agent)),
            ("manifest", backupPath),
            ("created_at", ISO8601DateFormatter().string(from: Date())),
            ("base_url", proxyURL),
            ("auth_token", redacted(apiKey))
        ])
    }

    private func expandedConfigPaths(for agent: CLIAgent) -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        return agent.configPaths.map { $0.replacingOccurrences(of: "~", with: home) }
    }

    private func capabilities(for agent: CLIAgent) async -> [String] {
        guard agent != .geminiCLI else {
            return ["guide", "diff"]
        }

        return await rollbackAvailable(for: agent)
            ? ["guide", "diff", "install", "rollback"]
            : ["guide", "diff", "install"]
    }

    private func caveats(for agent: CLIAgent) -> [String] {
        switch agent {
        case .geminiCLI:
            return ["Shell profile writes remain in the native macOS setup flow; shared UI provides guide and diff preview."]
        case .claudeCode, .ampCLI:
            return ["Automatic writes update app settings files; shell profile writes remain manual in the shared UI."]
        case .codexCLI, .openCode, .factoryDroid:
            return ["Automatic writes create timestamped backups before install and rollback."]
        }
    }

    private func rollbackAvailable(for agent: CLIAgent) async -> Bool {
        await !configurationService.listBackups(agent: agent).isEmpty
    }

    private func backupDirectory(for agent: CLIAgent) -> String? {
        expandedConfigPaths(for: agent).first.map { ($0 as NSString).deletingLastPathComponent }
    }

    private func redacted(_ value: String) -> String {
        value.isEmpty ? "" : "••••"
    }

    private func jsonObject(_ entries: [(String, Any?)]) -> [String: Any] {
        var object: [String: Any] = [:]
        for (key, value) in entries {
            if let value {
                object[key] = value
            }
        }
        return object
    }
}
