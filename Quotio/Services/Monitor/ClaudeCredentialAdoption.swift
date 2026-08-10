import Foundation

/// Copies the Claude Code CLI's keychain credential into Quotio's own keychain
/// item so quota polling never has to read an item Quotio does not own.
///
/// The CLI persists refreshed tokens with `security add-generic-password -U`,
/// which rebuilds the item from scratch and discards its ACL. Any "Always Allow"
/// grant the user gives Quotio therefore survives only until the CLI's next
/// token refresh, so reading that item on a poll loop produces an authorization
/// prompt several times a day. Adopting the credential once trades all of those
/// for a single prompt.
///
/// The copy is strictly read-only with respect to the CLI. Quotio never writes
/// the CLI's item and never refreshes the adopted credential: the CLI serializes
/// refreshes across its own processes with a lock and treats a spent refresh
/// token as fatal (`invalid_grant` -> token marked dead -> cleared from disk),
/// so an unsynchronized refresh from Quotio could log the user out of Claude
/// Code. The adopted copy is used until it expires and no further; continuous
/// monitoring comes from signing in to Quotio, which yields an independent
/// credential Quotio may refresh freely.
actor ClaudeCredentialAdopter {
    static let shared = ClaudeCredentialAdopter()

    nonisolated static let service = "Claude Code-credentials"

    /// Marks a vault account as a copy of the CLI's credential rather than one
    /// obtained by signing in to Quotio. Refreshing is only safe for the latter.
    nonisolated static let credentialReference = "keychain:claude-code-copy"

    /// Wait before touching the CLI's item again after an adoption that did not
    /// yield a usable credential — a denied prompt must not become a prompt per
    /// poll.
    private let failureBackoff: TimeInterval = 6 * 3600

    private let vault: MonitorCredentialStore
    private var nextAttempt: Date?

    init(vault: MonitorCredentialStore = MonitorCredentialVault.shared) {
        self.vault = vault
    }

    /// True when the account is a copy of the CLI's credential, whose refresh
    /// token is shared with Claude Code and must not be spent.
    nonisolated static func isCopyOfCLICredential(_ account: MonitorAccount) -> Bool {
        account.credentialReference == credentialReference
    }

    /// The Quotio-owned Claude credential, performing the one-time copy from the
    /// CLI's keychain item if it has not happened yet.
    @discardableResult
    func adoptIfNeeded() async -> MonitorAccount? {
        if let owned = await ownedAccount() { return owned }
        return await adopt()
    }

    /// Existing Quotio-owned Claude credential, if any. Never reads the CLI item.
    /// An account from signing in to Quotio takes precedence over an adopted copy,
    /// since only it can be kept alive by refreshing.
    func ownedAccount() async -> MonitorAccount? {
        let owned = await vault.accounts().filter { $0.provider == .claude && $0.source == .quotioKeychain }
        return owned.first { !Self.isCopyOfCLICredential($0) } ?? owned.first
    }

    private func adopt() async -> MonitorAccount? {
        if let nextAttempt, Date() < nextAttempt { return nil }

        guard let record = KeychainHelper.readExternalCredentialRecord(service: Self.service),
              let parsed = Self.parse(record.data) else {
            nextAttempt = Date().addingTimeInterval(failureBackoff)
            return nil
        }

        // Not deletable: the credential belongs to the CLI login, and deleting the
        // copy would only make the next discovery pass adopt it again — prompting
        // once more in the process. Disabling the account is the way to opt out.
        let account = MonitorAccount.make(
            provider: .claude,
            accountKey: parsed.email,
            source: .quotioKeychain,
            credentialReference: Self.credentialReference
        )

        do {
            try await vault.save(parsed.credential, metadata: account)
        } catch {
            nextAttempt = Date().addingTimeInterval(failureBackoff)
            Log.keychain("Claude credential adoption failed: \(error.localizedDescription)")
            return nil
        }

        nextAttempt = Date().addingTimeInterval(failureBackoff)
        Log.keychain("Adopted Claude Code credential for \(parsed.email) into Quotio's keychain")
        return account
    }

    /// Decode the CLI's credential blob into the vault's representation.
    nonisolated static func parse(_ data: Data) -> (credential: MonitorOAuthCredential, email: String)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = (oauth["accessToken"] as? String)?.nilIfBlank else { return nil }

        var extra: [String: String] = [:]
        if let subscription = (oauth["subscriptionType"] as? String)?.nilIfBlank {
            extra["subscriptionType"] = subscription
        }

        // The refresh token is deliberately dropped: it belongs to Claude Code's
        // refresh lineage and spending it would invalidate the CLI's own copy.
        let credential = MonitorOAuthCredential(
            accessToken: accessToken,
            refreshToken: nil,
            idToken: nil,
            accountID: nil,
            expiresAt: expiryDate(oauth["expiresAt"]),
            extra: extra
        )
        return (credential, (oauth["email"] as? String)?.nilIfBlank ?? "Claude Code")
    }

    /// Claude Code stores expiry as epoch milliseconds.
    private nonisolated static func expiryDate(_ value: Any?) -> Date? {
        guard let milliseconds = (value as? NSNumber)?.doubleValue, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

private extension String {
    nonisolated var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
