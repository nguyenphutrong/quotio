//
//  SmallProgressView.swift
//  Quotio
//
//  A workaround for SwiftUI ProgressView constraint issues on macOS.
//  Using .controlSize(.small) with ProgressView causes AppKit layout
//  constraint conflicts due to floating-point precision issues with
//  intrinsic size (~16.5 points).
//
//  This component uses scaleEffect instead, which avoids the issue
//  by not modifying the underlying NSProgressIndicator's intrinsic size.
//

import SwiftUI

/// A small indeterminate progress indicator that avoids AppKit constraint issues.
///
/// Use this instead of `ProgressView().controlSize(.small)` to prevent
/// the "maximum length that doesn't satisfy min <= max" constraint error.
struct SmallProgressView: View {
    private let size: CGFloat
    
    /// Creates a small progress view.
    /// - Parameter size: The size of the progress view (default: 16)
    init(size: CGFloat = 16) {
        self.size = size
    }
    
    var body: some View {
        ProgressView()
            .scaleEffect(size / 32) // Scale from default size (~32) to target
            .frame(width: size, height: size)
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
