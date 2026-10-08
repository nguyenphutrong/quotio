import AppKit
import QuotioApplication
import QuotioDomain
import SwiftUI

public struct AboutScreen: View {
    public init() {}
    @Environment(OperatingModeManager.self) private var modeManager
    @Environment(ApplicationUpdateScreenModel.self) private var updateModel
    @State private var showCopiedToast = false
    @State private var isHoveringVersion = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Hero Section
                heroSection

                // Description
                descriptionSection

                // Updates Grid
                updatesSection

                Divider()
                    .frame(maxWidth: 500)

                // Links Grid
                linksSection

                Spacer(minLength: 40)

                // Footer
                footerSection
            }
            .frame(maxWidth: .infinity)
            .padding(40)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if showCopiedToast {
                versionCopyToast
                    .transition(.opacity)
            }
        }
        .onAppear {
            updateModel.initializeIfNeeded()
        }
        .navigationTitle("nav.about".localized())
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: 20) {
            // App Icon with gradient glow
            ZStack {
                // Glow effect
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.blue.opacity(0.2),
                                Color.purple.opacity(0.1),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 160, height: 160)
                    .blur(radius: 40)

                Image("AppIconImage")
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 8)
            }

            // App Name & Tagline
            VStack(spacing: 8) {
                Text("Quotio")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("about.tagline".localized())
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            // Version Badges
            HStack(spacing: 12) {
                VersionBadge(
                    label: "Version",
                    value: appVersion,
                    icon: "tag"
                )
                .onHover { hovering in
                    isHoveringVersion = hovering
                }

                VersionBadge(
                    label: "Build",
                    value: buildNumber,
                    icon: "hammer.fill"
                )
            }
        }
        .padding(.top, 20)
    }

    // MARK: - Description Section

    private var descriptionSection: some View {
        Text("about.description".localized())
            .font(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 500)
    }

    // MARK: - Updates Section

    private var updatesSection: some View {
        VStack(spacing: 12) {
            AboutUpdateCard()

            if modeManager.isLocalProxyMode {
                AboutProxyUpdateCard()
            }
        }
        .frame(maxWidth: 500)
    }

    // MARK: - Links Section

    private var linksSection: some View {
        VStack(spacing: 16) {
            Text("Links")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                LinkCard(
                    title: "GitHub: Quotio",
                    icon: "link",
                    color: .blue,
                    url: URL(string: "https://github.com/nguyenphutrong/quotio")!
                )

                LinkCard(
                    title: "GitHub: CLIProxyAPI",
                    icon: "link",
                    color: .purple,
                    url: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!
                )

                LinkCard(
                    title: "about.support".localized(),
                    icon: "heart.fill",
                    color: .pink,
                    url: URL(string: "https://www.quotio.dev/sponsors")!
                )
            }
        }
        .frame(maxWidth: 500)
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        VStack(spacing: 8) {
            Text("about.madeWith".localized())
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 16)
    }

    // MARK: - Version Copy Toast

    private var versionCopyToast: some View {
        VStack {
            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Version copied to clipboard")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Version Badge

struct VersionBadge: View {
    let label: String
    let value: String
    let icon: String
    @Environment(PasteboardScreenModel.self) private var pasteboard

    @State private var isHovered = false

    var body: some View {
        Button {
            pasteboard.copy(value)
        } label: {
            HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(isHovered ? .blue : .secondary)

                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(isHovered ? .blue : .secondary)

                Text(value)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isHovered ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.05),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isHovered ? Color.blue.opacity(0.3) : Color.secondary.opacity(0.2),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - About Update Card

struct AboutUpdateCard: View {
    @Environment(SettingsScreenModel.self) private var settingsModel
    @Environment(ApplicationUpdateScreenModel.self) private var updateModel
    @State private var isHovered = false

    private var autoCheckUpdatesBinding: Binding<Bool> {
        Binding(
            get: { settingsModel.appShellPreferences.autoCheckUpdates },
            set: { settingsModel.setAutomaticUpdateChecks($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader(
                title: "settings.updates".localized(),
                systemImage: "arrow.down.circle",
                color: .blue
            )

            HStack {
                Text("settings.autoCheckUpdates".localized())
                    .font(.subheadline)
                Spacer()
                Toggle("", isOn: autoCheckUpdatesBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Divider()

            HStack {
                Text("settings.lastChecked".localized())
                Spacer()
                if let date = updateModel.snapshot.lastCheckDate {
                    Text(date, style: .relative)
                        .foregroundStyle(.secondary)
                } else {
                    Text("settings.never".localized())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()

                Button("settings.checkNow".localized()) {
                    updateModel.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(
            color: .black.opacity(isHovered ? 0.08 : 0.04),
            radius: isHovered ? 8 : 4,
            x: 0,
            y: isHovered ? 2 : 1
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - About Proxy Update Card

struct AboutProxyUpdateCard: View {
    @Environment(ProxyManagementScreenModel.self) private var viewModel
    @State private var isHovered = false
    @State private var showAdvancedSheet = false
    @State private var isCheckingForUpdate = false
    @State private var isUpgrading = false
    @State private var upgradeError: String?

    private var proxyManager: ProxyScreenModel {
        viewModel.proxy
    }

    private var currentVersionText: String {
        if let version = proxyManager.currentVersion ?? proxyManager.installedProxyVersion {
            return "v\(version)"
        }
        return "Not installed"
    }

    private var statusText: String {
        if proxyManager.currentVersion == nil && proxyManager.installedProxyVersion == nil {
            return "Install required"
        }

        if proxyManager.upgradeAvailable, let upgrade = proxyManager.availableUpgrade {
            return "Update available: v\(upgrade.version)"
        }

        return "Up to date"
    }

    private var statusColor: Color {
        if upgradeError != nil {
            return .orange
        }
        if proxyManager.upgradeAvailable {
            return .green
        }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader(
                title: "settings.proxyUpdate".localized(),
                systemImage: "shippingbox.and.arrow.backward",
                color: .purple
            )

            HStack {
                Text("settings.proxyUpdate.currentVersion".localized())
                Spacer()
                Text(currentVersionText)
                    .font(.system(.subheadline, design: .monospaced))
                    .fontWeight(.medium)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor == .secondary ? .secondary : .primary)
            }

            if let lastCheck = proxyManager.lastProxyUpdateCheckDate {
                HStack {
                    Text("Last checked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(lastCheck, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = upgradeError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button {
                    checkForUpdate()
                } label: {
                    ZStack {
                        Text("settings.proxyUpdate.checkNow".localized())
                            .opacity(isCheckingForUpdate ? 0 : 1)

                        if isCheckingForUpdate {
                            SmallProgressView()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isCheckingForUpdate)

                if let upgrade = proxyManager.availableUpgrade {
                    Button {
                        performUpgrade(to: upgrade)
                    } label: {
                        ZStack {
                            Text("action.update".localized())
                                .opacity(isUpgrading ? 0 : 1)

                            if isUpgrading {
                                SmallProgressView()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isUpgrading)
                }

                Spacer()

                Button {
                    showAdvancedSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Text("settings.proxyUpdate.advanced".localized())
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(
            color: .black.opacity(isHovered ? 0.08 : 0.04),
            radius: isHovered ? 8 : 4,
            x: 0,
            y: isHovered ? 2 : 1
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .sheet(isPresented: $showAdvancedSheet) {
            ProxyVersionManagerSheet()
                .environment(viewModel)
        }
    }

    private func checkForUpdate() {
        isCheckingForUpdate = true
        upgradeError = nil

        Task { @MainActor in
            defer {
                // Always reset loading state
                isCheckingForUpdate = false
            }

            await proxyManager.checkForUpgrade()
        }
    }

    private func performUpgrade(to version: ProxyVersionInfo) {
        isUpgrading = true
        upgradeError = nil

        Task { @MainActor in
            do {
                try await proxyManager.performManagedUpgrade(to: version)
                isUpgrading = false
            } catch {
                upgradeError = proxyManager.errorMessage(for: error)
                isUpgrading = false
            }
        }
    }
}

private func cardHeader(title: String, systemImage: String, color: Color) -> some View {
    HStack {
        Image(systemName: systemImage)
            .font(.title3)
            .foregroundStyle(color)
        Text(title)
            .font(.headline)
        Spacer()
    }
}

// MARK: - Link Card

struct LinkCard: View {
    let title: String
    let icon: String
    let color: Color
    let url: URL?
    let action: (() -> Void)?
    @Environment(PlatformActionScreenModel.self) private var platformActions

    @State private var isHovered = false

    init(
        title: String,
        icon: String,
        color: Color,
        url: URL? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.icon = icon
        self.color = color
        self.url = url
        self.action = action
    }

    var body: some View {
        Button {
            if let url = url {
                platformActions.open(url)
            } else if let action = action {
                action()
            }
        } label: {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    Circle()
                        .fill(color.opacity(isHovered ? 0.15 : 0.08))
                        .frame(width: 40, height: 40)

                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(isHovered ? color : .secondary)
                }

                // Title
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(isHovered ? color : .primary)

                Spacer()

                // Arrow icon (for links)
                if url != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(isHovered ? color : .secondary.opacity(0.5))
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isHovered ? color.opacity(0.3) : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .shadow(
                color: .black.opacity(isHovered ? 0.1 : 0.03),
                radius: isHovered ? 10 : 4,
                x: 0,
                y: isHovered ? 3 : 1
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
