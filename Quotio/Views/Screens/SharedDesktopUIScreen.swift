//
//  SharedDesktopUIScreen.swift
//  Quotio
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum SharedDesktopUIFeature {
    static var isEnabled: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["QUOTIO_ENABLE_SHARED_UI"] == "1"
            || environment["QUOTIO_DESKTOP_UI_DEV_SERVER"]?.isEmpty == false
        #else
        return false
        #endif
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
        .navigationTitle("nav.sharedUI".localized())
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
    static let version = 1

    enum RequestKind {
        static let managementRequest = "management.request"
        static let nativeConfirm = "native.confirm"
        static let nativeOpenExternal = "native.openExternal"
        static let nativeOpenTextFile = "native.openTextFile"
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

        let webView = NativeDesktopWebView(frame: .zero, configuration: configuration)
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

final class NativeDesktopWebView: WKWebView {
    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }
}

@MainActor
final class BridgeCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let messageName = "quotioBridge"

    private weak var webView: WKWebView?
    private weak var viewModel: QuotaViewModel?
    private var bootstrap: WebViewBootstrap

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
        [
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
                "agents": false,
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
                "supportsNativeOnboarding": true,
                "supportsAppearanceSync": true,
                "supportsRequestLogSettings": true,
                "supportsModelSettings": true,
                "supportsApiKeyManagement": true,
                "supportsVirtualModelManagement": true
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
                case DesktopBridgeContract.RequestKind.managementRequest:
                    value = try await handleManagementRequest(body)
                case DesktopBridgeContract.RequestKind.nativeConfirm:
                    value = handleNativeConfirm(body)
                case DesktopBridgeContract.RequestKind.nativeOpenExternal:
                    value = try handleNativeOpenExternal(body)
                case DesktopBridgeContract.RequestKind.nativeOpenTextFile:
                    value = try handleNativeOpenTextFile(body) ?? NSNull()
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
