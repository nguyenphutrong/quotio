import Foundation

/// GitHub host used for Copilot device authorization.
///
/// Only GitHub.com and GitHub Enterprise Cloud with data residency
/// (`<subdomain>.ghe.com`) are accepted. Self-hosted GitHub Enterprise Server
/// needs an OAuth app registered on that instance, so arbitrary hosts are
/// rejected instead of receiving a device code or token. The bundled CLI
/// enforces the same host rule on the normalized bare host this type produces.
public struct GitHubHost: Hashable, Sendable {
    public static let githubCom = GitHubHost(uncheckedValue: "github.com")

    private static let dataResidencySuffix = ".ghe.com"

    public let value: String

    private init(uncheckedValue: String) {
        self.value = uncheckedValue
    }

    /// Accepts a bare host name. A leading `https://` and a single trailing `/`
    /// are tolerated because users commonly paste the enterprise URL; ports,
    /// paths, credentials, queries and nested subdomains are rejected.
    public init?(_ raw: String) {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("https://") { host.removeFirst("https://".count) }
        if host.hasSuffix("/") { host.removeLast() }
        guard !host.isEmpty, host.count <= 253, host.allSatisfy(\.isASCII) else { return nil }
        if host == Self.githubCom.value {
            self.init(uncheckedValue: host)
            return
        }
        guard host.hasSuffix(Self.dataResidencySuffix) else { return nil }
        let subdomain = host.dropLast(Self.dataResidencySuffix.count)
        guard !subdomain.isEmpty,
              subdomain.count <= 63,
              subdomain.first != "-",
              subdomain.last != "-",
              subdomain.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" })
        else { return nil }
        self.init(uncheckedValue: host)
    }

    public var isGitHubCom: Bool { self == Self.githubCom }
}
