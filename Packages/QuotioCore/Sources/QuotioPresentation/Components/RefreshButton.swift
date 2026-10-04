import SwiftUI

/// Keeps feedback active for the entire action, including work before quota fetching.
struct RefreshButton: View {
    let title: String
    var isRefreshing = false
    let action: @MainActor () async -> Void
    @State private var isRunning = false

    var body: some View {
        Button {
            guard !isRunning, !isRefreshing else { return }
            isRunning = true
            Task {
                defer { isRunning = false }
                await action()
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                ZStack {
                    Image(systemName: "arrow.clockwise")
                        .opacity(isRunning || isRefreshing ? 0 : 1)
                    if isRunning || isRefreshing { SmallProgressView() }
                }
                .frame(width: 16, height: 16)
            }
        }
        .disabled(isRunning || isRefreshing)
        .accessibilityLabel(title)
        .accessibilityValue(isRunning || isRefreshing ? "status.refreshing".localized() : "")
    }
}
