//
//  StatusBarManager.swift
//  Quotio
//
//  Custom NSStatusBar manager with native NSMenu for Liquid Glass appearance.
//  Uses NSMenu with SwiftUI hosting views for native macOS styling.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class StatusBarManager: NSObject, NSMenuDelegate {
    static let shared = StatusBarManager()
    
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var menuContentProvider: (() -> AnyView)?
    private var menuContentVersion: Int = 0
    private let menuWidth: CGFloat = 300
    
    // Native menu builder
    private var menuBuilder: StatusBarMenuBuilder?
    private weak var viewModel: QuotaViewModel?
    
    private override init() {
        super.init()
    }
    
    func setViewModel(_ viewModel: QuotaViewModel) {
        self.viewModel = viewModel
        self.menuBuilder = StatusBarMenuBuilder(viewModel: viewModel)
        MenuActionHandler.shared.viewModel = viewModel
    }
    
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
        
        // Store content provider for menu refresh
        self.menuContentProvider = menuContentProvider
        self.menuContentVersion += 1
        
        // Create or update menu
        if menu == nil {
            menu = NSMenu()
            menu?.autoenablesItems = false
            menu?.delegate = self
        }
        
        // Attach menu to status item
        statusItem?.menu = menu
        
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
        
        // Add horizontal padding to align with native status bar spacing
        let horizontalPadding: CGFloat = 4
        let contentSize = hostingView.intrinsicContentSize
        let containerSize = NSSize(
            width: contentSize.width + horizontalPadding * 2,
            height: max(22, contentSize.height)
        )
        
        let containerView = StatusBarContainerView(frame: NSRect(origin: .zero, size: containerSize))
        containerView.addSubview(hostingView)
        hostingView.frame = NSRect(
            x: horizontalPadding,
            y: (containerSize.height - contentSize.height) / 2,
            width: contentSize.width,
            height: contentSize.height
        )
        
        button.addSubview(containerView)
        button.frame = NSRect(origin: .zero, size: containerSize)
        statusItem?.length = containerSize.width
    }
    
    // MARK: - NSMenuDelegate
    
    func menuWillOpen(_ menu: NSMenu) {
        populateMenu()
    }
    
    func menuDidClose(_ menu: NSMenu) {
        // Cleanup
    }
    
    /// Force rebuild menu while it's open (e.g., when provider changes)
    func rebuildMenuInPlace() {
        guard let menu = menu else { return }
        populateMenu()
        menu.update()
    }
    
    private func populateMenu() {
        guard let menu = menu else { return }
        
        menu.removeAllItems()
        
        // Use native menu builder if available
        if let builder = menuBuilder {
            let nativeMenu = builder.buildMenu()
            for item in nativeMenu.items {
                nativeMenu.removeItem(item)
                menu.addItem(item)
            }
            return
        }
        
        // Fallback to SwiftUI hosting view
        guard let contentProvider = menuContentProvider else { return }
        
        let content = contentProvider()
        let wrappedContent = MenuContentWrapper(content: content, width: menuWidth)
        let hostingView = MenuHostingView(rootView: wrappedContent, fixedWidth: menuWidth)
        
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        
        let containerView = MenuContainerView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(hostingView)
        
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.widthAnchor.constraint(equalToConstant: menuWidth)
        ])
        
        containerView.layoutSubtreeIfNeeded()
        
        let fittingSize = containerView.fittingSize
        let height = max(50, fittingSize.height.isFinite ? fittingSize.height : 300)
        containerView.frame = NSRect(origin: .zero, size: NSSize(width: menuWidth, height: height))
        
        let contentItem = NSMenuItem()
        contentItem.view = containerView
        contentItem.representedObject = "menuContent"
        menu.addItem(contentItem)
        
        DispatchQueue.main.async { [weak containerView, weak menu] in
            guard let containerView, let menu else { return }
            containerView.layoutSubtreeIfNeeded()
            let newSize = containerView.fittingSize
            let newHeight = max(50, newSize.height.isFinite ? newSize.height : containerView.frame.height)
            if abs(newHeight - containerView.frame.height) > 1 {
                containerView.frame = NSRect(origin: .zero, size: NSSize(width: 300, height: newHeight))
                menu.update()
            }
        }
    }
    
    // MARK: - Menu Actions
    
    /// Force refresh menu content on next open
    func invalidateMenuContent() {
        menuContentVersion += 1
    }
    
    func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        menu = nil
    }
}

// MARK: - Menu Content Wrapper

/// Wrapper view that enforces fixed width for proper height calculation
private struct MenuContentWrapper: View {
    let content: AnyView
    let width: CGFloat
    
    var body: some View {
        content
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Menu Container View

/// Container view for menu items that supports vibrancy
private final class MenuContainerView: NSView {
    override var allowsVibrancy: Bool { true }
    
    override var intrinsicContentSize: NSSize {
        // Return fitting size based on subviews
        guard let hostingView = subviews.first else {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        return hostingView.fittingSize
    }
    
    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }
}

// MARK: - Menu Hosting View

/// Custom NSHostingView that enables vibrancy and provides accurate height measurement
private final class MenuHostingView<Content: View>: NSHostingView<Content> {
    
    private let fixedWidth: CGFloat
    
    override var allowsVibrancy: Bool { true }
    
    /// Override intrinsicContentSize to provide accurate sizing for NSMenu
    override var intrinsicContentSize: NSSize {
        // Use sizeThatFits for accurate measurement
        let controller = NSHostingController(rootView: self.rootView)
        let measured = controller.sizeThatFits(in: CGSize(width: fixedWidth, height: CGFloat.greatestFiniteMagnitude))
        let height = measured.height.isFinite ? measured.height : 300
        return NSSize(width: fixedWidth, height: max(50, height))
    }
    
    init(rootView: Content, fixedWidth: CGFloat) {
        self.fixedWidth = fixedWidth
        super.init(rootView: rootView)
        setupTransparency()
    }
    
    required init(rootView: Content) {
        self.fixedWidth = 300
        super.init(rootView: rootView)
        setupTransparency()
    }
    
    @available(*, unavailable)
    @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupTransparency() {
        wantsLayer = true
        layer?.backgroundColor = .clear
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = .clear
    }
    
    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = .clear
    }
}

// MARK: - Status Bar Container View

final class StatusBarContainerView: NSView {
    override var allowsVibrancy: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }
    
    override func mouseUp(with event: NSEvent) {
        superview?.mouseUp(with: event)
    }
}

// MARK: - Status Bar Default View

struct StatusBarDefaultView: View {
    let isRunning: Bool
    
    var body: some View {
        Image(systemName: isRunning ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.0percent")
            .font(.system(size: 14))
            .frame(height: 22)
    }
}

// MARK: - Status Bar Quota View

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

// MARK: - Status Bar Quota Item View

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
