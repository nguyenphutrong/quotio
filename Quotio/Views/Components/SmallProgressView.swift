//
//  SmallProgressView.swift
//  Quotio
//
//  A workaround for SwiftUI ProgressView constraint issues on macOS.
//  Using .controlSize(.small) with ProgressView causes AppKit layout
//  constraint conflicts due to floating-point precision issues with
//  intrinsic size (~16.5 points).
//
//  This component uses NSProgressIndicator directly via NSViewRepresentable
//  to avoid the SwiftUI/AppKit constraint bridging issues.
//

import SwiftUI
import AppKit

/// A small indeterminate progress indicator that avoids AppKit constraint issues.
///
/// Use this instead of `ProgressView().controlSize(.small)` to prevent
/// the "maximum length that doesn't satisfy min <= max" constraint error.
struct SmallProgressView: View {
    let size: CGFloat
    
    init(size: CGFloat = 16) {
        self.size = size
    }
    
    var body: some View {
        SmallProgressIndicator()
            .frame(width: size, height: size)
    }
}

/// Internal NSViewRepresentable that creates a properly sized NSProgressIndicator
private struct SmallProgressIndicator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimation(nil)
        
        container.addSubview(indicator)
        
        // Center the indicator in the container
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        
        return container
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let indicator = nsView.subviews.first as? NSProgressIndicator {
            if !indicator.isHidden {
                indicator.startAnimation(nil)
            }
        }
    }
}

#Preview {
    HStack(spacing: 20) {
        VStack {
            SmallProgressView()
            Text("Default (16)")
                .font(.caption)
        }
        
        VStack {
            SmallProgressView(size: 8)
            Text("Size 8")
                .font(.caption)
        }
        
        VStack {
            SmallProgressView(size: 12)
            Text("Size 12")
                .font(.caption)
        }
        
        VStack {
            SmallProgressView(size: 20)
            Text("Size 20")
                .font(.caption)
        }
    }
    .padding()
}
