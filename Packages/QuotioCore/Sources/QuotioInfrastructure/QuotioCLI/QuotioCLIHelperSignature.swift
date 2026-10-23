import Foundation
import Security

public enum QuotioCLIHelperSignature {
    private static let developerIDIntermediateMarker = "1.2.840.113635.100.6.2.6"

    // Read from the running app's own signature so no Team ID is committed.
    private static let hostTeamIdentifier: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess,
              let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any] else {
            return nil
        }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    private static func standaloneCLIRequirement(team: String) -> String {
        #"identifier "dev.quotio.cli" and anchor apple generic and certificate 1[field.\#(developerIDIntermediateMarker)] exists and certificate leaf[subject.OU] = "\#(team)""#
    }

    public static func matchesStandaloneCLI(at url: URL) -> Bool {
        guard let team = hostTeamIdentifier else {
            return false
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(standaloneCLIRequirement(team: team) as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
