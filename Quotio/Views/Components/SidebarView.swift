//
//  SidebarView.swift
//  Quotio
//
//  Note: This file is no longer used - sidebar is now integrated in QuotioApp.swift
//  using NavigationSplitView which automatically gets Liquid Glass styling.
//

import SwiftUI

// Legacy SidebarView - kept for reference
struct SidebarView: View {
    @Binding var isExpanded: Bool
    @Binding var isPinned: Bool
    
    var body: some View {
        // Now using NavigationSplitView in QuotioApp.swift
        EmptyView()
    }
}
