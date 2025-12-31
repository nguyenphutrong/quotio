//
//  QuotioButtonStyles.swift
//  Quotio
//
//  Custom button styles for consistent focus ring handling across the app.
//  These styles provide subtle or no focus rings while maintaining accessibility.
//

import SwiftUI

// MARK: - Subtle Button Style

/// A button style with no default focus ring, suitable for icon buttons and inline actions.
/// Use this for: trash buttons, toggle buttons, small action buttons.
struct SubtleButtonStyle: ButtonStyle {
    var hoverColor: Color = .primary.opacity(0.1)
    var pressedOpacity: Double = 0.6
    var cornerRadius: CGFloat = 6
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? pressedOpacity : 1.0)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(configuration.isPressed ? hoverColor : .clear)
            )
            .focusEffectDisabled(true)
    }
}

// MARK: - Row Action Button Style

/// A button style for action buttons within list rows (like delete, edit, toggle).
/// No focus ring, subtle press feedback.
struct RowActionButtonStyle: ButtonStyle {
    var foregroundColor: Color = .primary
    var pressedOpacity: Double = 0.5
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foregroundColor)
            .opacity(configuration.isPressed ? pressedOpacity : 1.0)
            .focusEffectDisabled(true)
    }
}

// MARK: - Menu Row Button Style

/// A button style for menu-like row buttons (like in popovers).
/// Shows hover background, no focus ring.
struct MenuRowButtonStyle: ButtonStyle {
    var hoverColor: Color = .primary.opacity(0.08)
    var cornerRadius: CGFloat = 6
    
    @State private var isHovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(configuration.isPressed ? hoverColor.opacity(1.5) : (isHovered ? hoverColor : .clear))
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
            .focusEffectDisabled(true)
    }
}

// MARK: - Grid Item Button Style

/// A button style for grid items (like provider buttons in popover).
/// Shows hover background with provider color tint.
struct GridItemButtonStyle: ButtonStyle {
    var hoverColor: Color = .accentColor.opacity(0.1)
    var cornerRadius: CGFloat = 8
    
    @State private var isHovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(configuration.isPressed ? hoverColor.opacity(1.5) : (isHovered ? hoverColor : .clear))
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
            .focusEffectDisabled(true)
    }
}

// MARK: - Toolbar Icon Button Style

/// A button style for toolbar icon buttons.
/// Subtle hover effect, no focus ring.
struct ToolbarIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var cornerRadius: CGFloat = 6
    
    @State private var isHovered = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.15) : (isHovered ? Color.primary.opacity(0.08) : .clear))
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
            .focusEffectDisabled(true)
    }
}

// MARK: - Section Header Button Style

/// A button style for buttons in section headers (like refresh, add).
/// Minimal styling, no focus ring.
struct SectionHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1.0)
            .focusEffectDisabled(true)
    }
}

// MARK: - Extensions for Convenience

extension ButtonStyle where Self == SubtleButtonStyle {
    /// A button style with no focus ring for icon/action buttons.
    static var subtle: SubtleButtonStyle { SubtleButtonStyle() }
}

extension ButtonStyle where Self == RowActionButtonStyle {
    /// A button style for action buttons within rows.
    static var rowAction: RowActionButtonStyle { RowActionButtonStyle() }
    
    /// A destructive row action button style.
    static var rowActionDestructive: RowActionButtonStyle {
        RowActionButtonStyle(foregroundColor: .red.opacity(0.8))
    }
}

extension ButtonStyle where Self == MenuRowButtonStyle {
    /// A button style for menu-like row buttons.
    static var menuRow: MenuRowButtonStyle { MenuRowButtonStyle() }
}

extension ButtonStyle where Self == GridItemButtonStyle {
    /// A button style for grid items.
    static var gridItem: GridItemButtonStyle { GridItemButtonStyle() }
    
    /// A grid item button style with custom hover color.
    static func gridItem(hoverColor: Color) -> GridItemButtonStyle {
        GridItemButtonStyle(hoverColor: hoverColor)
    }
}

extension ButtonStyle where Self == ToolbarIconButtonStyle {
    /// A button style for toolbar icon buttons.
    static var toolbarIcon: ToolbarIconButtonStyle { ToolbarIconButtonStyle() }
}

extension ButtonStyle where Self == SectionHeaderButtonStyle {
    /// A button style for section header buttons.
    static var sectionHeader: SectionHeaderButtonStyle { SectionHeaderButtonStyle() }
}

// MARK: - Preview

#Preview("Button Styles") {
    VStack(spacing: 20) {
        // Subtle
        HStack {
            Text("Subtle:")
            Button { } label: {
                Image(systemName: "trash")
                    .padding(8)
            }
            .buttonStyle(.subtle)
        }
        
        // Row Action
        HStack {
            Text("Row Action:")
            Button { } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.rowAction)
            
            Button { } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.rowActionDestructive)
        }
        
        // Menu Row
        HStack {
            Text("Menu Row:")
            Button { } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings")
                    Spacer()
                }
                .frame(width: 150)
            }
            .buttonStyle(.menuRow)
        }
        
        // Grid Item
        HStack {
            Text("Grid Item:")
            Button { } label: {
                VStack {
                    Image(systemName: "star.fill")
                        .font(.title)
                    Text("Item")
                        .font(.caption)
                }
                .frame(width: 60, height: 60)
            }
            .buttonStyle(.gridItem(hoverColor: .blue.opacity(0.1)))
        }
        
        // Toolbar Icon
        HStack {
            Text("Toolbar Icon:")
            Button { } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.toolbarIcon)
        }
        
        // Section Header
        HStack {
            Text("Section Header:")
            Button { } label: {
                Label("Add", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.sectionHeader)
        }
    }
    .padding()
}
