//
//  CopyButton.swift
//  Quotio
//
//  Unified reusable copy-to-clipboard button with subtle feedback.
//

import SwiftUI
import AppKit

/// Reusable button for copy-to-clipboard actions with visual feedback.
///
/// You can:
/// - Pass concrete `text` to copy, OR
/// - Pass a custom `onCopy` closure if you need custom behaviour.
struct CopyButton: View {
    /// Optional title to show next to the icon. When `nil`, shows icon only.
    let title: String?
    /// Optional text to copy to the clipboard. If `nil`, `onCopy` must handle copying.
    let text: String?
    /// Optional custom copy handler. If `nil`, the control copies `text` (if provided).
    let onCopy: (() -> Void)?
    
    @State private var isCopied = false
    
    init(
        title: String? = nil,
        text: String? = nil,
        onCopy: (() -> Void)? = nil
    ) {
        self.title = title
        self.text = text
        self.onCopy = onCopy
    }
    
    var body: some View {
        Button {
            handleCopy()
            provideFeedback()
        } label: {
            labelContent
        }
        .help(isCopied ? "action.copied".localized() : "action.copy".localized())
    }
    
    // MARK: - Private
    
    @ViewBuilder
    private var labelContent: some View {
        let systemImage = isCopied ? "checkmark.circle.fill" : "doc.on.doc"
        
        if let title {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
        }
    }
    
    private func handleCopy() {
        if let onCopy {
            onCopy()
        } else if let text {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
    
    private func provideFeedback() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isCopied = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.15)) {
                isCopied = false
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        CopyButton(title: "Copy Text", text: "Example text")
        CopyButton(title: nil, text: "Example text")
    }
    .padding()
}


