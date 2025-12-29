//
//  StatusBarManager.swift
//  Quotio
//
//  Custom NSStatusBar manager with single combined status item using NSPanel
//  Uses NSPanel instead of NSPopover to support full-screen mode
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class StatusBarManager {
    static let shared = StatusBarManager()
    
    private var statusItem: NSStatusItem?
    private var menuPanel: StatusBarPanel?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    
    private init() {}
    
    func updateStatusBar(
        items: [MenuBarQuotaDisplayItem],
        colorMode: MenuBarColorMode,
        isRunning: Bool,
        showMenuBarIcon: Bool,
        showQuota: Bool,
        menuContentProvider: @escaping () -> AnyView
    ) {
        guard showMenuBarIcon else {
            removeStatusItem()
            return
        }
        
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        
        // Create or update panel
        if menuPanel == nil {
            menuPanel = StatusBarPanel()
        }
        menuPanel?.updateContent(menuContentProvider())
        
        guard let button = statusItem?.button else { return }
        
        button.subviews.forEach { $0.removeFromSuperview() }
        button.title = ""
        button.image = nil
        
        let contentView: AnyView
        if !showQuota || !isRunning || items.isEmpty {
            contentView = AnyView(
                StatusBarDefaultView(isRunning: isRunning)
            )
        } else {
            contentView = AnyView(
                StatusBarQuotaView(items: items, colorMode: colorMode)
            )
        }
        
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.setFrameSize(hostingView.intrinsicContentSize)
        
        let containerView = StatusBarContainerView(frame: NSRect(origin: .zero, size: hostingView.intrinsicContentSize))
        containerView.addSubview(hostingView)
        hostingView.frame = containerView.bounds
        
        button.addSubview(containerView)
        button.frame = NSRect(origin: .zero, size: hostingView.intrinsicContentSize)
        
        button.action = #selector(statusItemClicked(_:))
        button.target = self
    }
    
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let panel = menuPanel else { return }
        
        if panel.isVisible {
            closePanel()
        } else {
            showPanel(relativeTo: sender)
        }
    }
    
    private func showPanel(relativeTo button: NSStatusBarButton) {
        guard let panel = menuPanel else { return }
        
        // Get button's screen position
        guard let buttonWindow = button.window else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        
        // Position panel below the button, aligned to the right edge
        let panelSize = panel.frame.size
        let panelX = screenRect.maxX - panelSize.width
        let panelY = screenRect.minY - panelSize.height - 4
        
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        panel.makeKeyAndOrderFront(nil)
        
        // Add global event monitor for clicks outside
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
        
        // Add local event monitor for escape key
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape key
                self?.closePanel()
                return nil
            }
            return event
        }
    }
    
    private func closePanel() {
        menuPanel?.orderOut(nil)
        
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }
    
    func removeStatusItem() {
        closePanel()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
}

// MARK: - StatusBarPanel

/// Custom NSPanel that works across all Spaces including full-screen mode
/// Uses NSVisualEffectView for consistent Liquid Glass appearance on macOS 15/26
final class StatusBarPanel: NSPanel {
    private var hostingView: TransparentHostingView?
    private var visualEffectView: NSVisualEffectView?
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        // Panel configuration for menu bar behavior
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
        self.isFloatingPanel = true
        
        // Important: Make the window fully transparent
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        
        // Create the visual effect view for background
        let visualEffect = NSVisualEffectView()
        visualEffect.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.material = .popover
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.masksToBounds = true
        
        // Adjust corner radius for OS version
        if #available(macOS 26.0, *) {
            visualEffect.layer?.cornerRadius = 18
        } else {
            visualEffect.layer?.cornerRadius = 10
        }
        
        self.visualEffectView = visualEffect
        
        // Create transparent hosting view
        let placeholderView = AnyView(EmptyView())
        hostingView = TransparentHostingView(rootView: placeholderView)
        hostingView?.translatesAutoresizingMaskIntoConstraints = false
        
        // Create a container view that clips to the rounded rect
        let containerView = ClippingContainerView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = true
        containerView.layer?.backgroundColor = .clear
        
        if #available(macOS 26.0, *) {
            containerView.layer?.cornerRadius = 18
        } else {
            containerView.layer?.cornerRadius = 10
        }
        
        self.contentView = containerView
        
        // Add visual effect as background
        containerView.addSubview(visualEffect)
        
        // Add hosting view on top
        if let hosting = hostingView {
            containerView.addSubview(hosting)
            
            NSLayoutConstraint.activate([
                // Visual effect fills container
                visualEffect.topAnchor.constraint(equalTo: containerView.topAnchor),
                visualEffect.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                visualEffect.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                visualEffect.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
                
                // Hosting view fills container
                hosting.topAnchor.constraint(equalTo: containerView.topAnchor),
                hosting.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                hosting.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ])
        }
    }
    
    func updateContent(_ content: AnyView) {
        hostingView?.rootView = content
        
        // Resize panel to fit content with dynamic height
        if let hosting = hostingView {
            let fittingSize = hosting.fittingSize
            
            // Validate dimensions to avoid "Invalid frame dimension" errors
            let width: CGFloat = 300
            let height = max(50, fittingSize.height.isFinite ? fittingSize.height : 200)
            
            let newSize = NSSize(width: width, height: height)
            self.setContentSize(newSize)
        }
    }
    
    override var canBecomeKey: Bool { true }
    
    // Prevent auto-focus on first responder when panel opens
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        // Only allow the panel itself or nil as first responder, not buttons
        if responder == nil || responder === self.contentView {
            return super.makeFirstResponder(responder)
        }
        return super.makeFirstResponder(self.contentView)
    }
    
    override func resignKey() {
        super.resignKey()
        // Close panel when it loses key status (user clicked elsewhere in app)
        self.orderOut(nil)
    }
}

/// Container view that clips content to its bounds with rounded corners
private final class ClippingContainerView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override var allowsVibrancy: Bool { true }
    
    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = .clear
    }
}

/// Custom NSHostingView that ensures transparent background
private final class TransparentHostingView: NSHostingView<AnyView> {
    
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        setupTransparency()
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupTransparency()
    }
    
    private func setupTransparency() {
        wantsLayer = true
        layer?.backgroundColor = .clear
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        
        // Ensure the view and all layers are transparent
        wantsLayer = true
        layer?.backgroundColor = .clear
        
        // Clear any intermediate layer backgrounds
        func clearLayerBackgrounds(in view: NSView) {
            view.wantsLayer = true
            view.layer?.backgroundColor = .clear
            for subview in view.subviews {
                clearLayerBackgrounds(in: subview)
            }
        }
        clearLayerBackgrounds(in: self)
    }
    
    override var allowsVibrancy: Bool { true }
    
    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = .clear
    }
}

class StatusBarContainerView: NSView {
    override var allowsVibrancy: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }
    
    override func mouseUp(with event: NSEvent) {
        superview?.mouseUp(with: event)
    }
}

struct StatusBarDefaultView: View {
    let isRunning: Bool
    
    var body: some View {
        Image(systemName: isRunning ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.0percent")
            .font(.system(size: 14))
            .frame(height: 22)
    }
}

struct StatusBarQuotaView: View {
    let items: [MenuBarQuotaDisplayItem]
    let colorMode: MenuBarColorMode
    
    var body: some View {
        HStack(spacing: 10) {
            ForEach(items) { item in
                StatusBarQuotaItemView(item: item, colorMode: colorMode)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
        .fixedSize()
    }
}

struct StatusBarQuotaItemView: View {
    let item: MenuBarQuotaDisplayItem
    let colorMode: MenuBarColorMode
    
    @State private var settings = MenuBarSettingsManager.shared
    
    var body: some View {
        let displayMode = settings.quotaDisplayMode
        let displayPercent = displayMode.displayValue(from: item.percentage)
        
        HStack(spacing: 2) {
            if let assetName = item.provider.menuBarIconAsset {
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
            } else {
                Text(item.provider.menuBarSymbol)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(colorMode == .colored ? item.provider.color : .primary)
                    .fixedSize()
            }
            
            Text(formatPercentage(displayPercent))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(colorMode == .colored ? item.statusColor : .primary)
                .fixedSize()
        }
        .fixedSize()
    }
    
    private func formatPercentage(_ value: Double) -> String {
        if value < 0 { return "--%"}
        return String(format: "%.0f%%", value.rounded())
    }
}
