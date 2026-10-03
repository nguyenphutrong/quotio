import XCTest
@testable import QuotioDomain

final class GitHubHostTests: XCTestCase {
    func testAcceptsGitHubComAndDataResidencyHosts() {
        XCTAssertEqual(GitHubHost("github.com"), .githubCom)
        XCTAssertTrue(GitHubHost("GitHub.com")?.isGitHubCom == true)
        XCTAssertEqual(GitHubHost("octocorp.ghe.com")?.value, "octocorp.ghe.com")
        XCTAssertEqual(GitHubHost(" Octo-Corp1.GHE.com ")?.value, "octo-corp1.ghe.com")
    }

    func testToleratesPastedEnterpriseURL() {
        XCTAssertEqual(GitHubHost("https://octocorp.ghe.com/")?.value, "octocorp.ghe.com")
    }

    func testRejectsHostsThatCouldRedirectCredentials() {
        let rejected = [
            "",
            "http://octocorp.ghe.com",
            "https://octocorp.ghe.com/login",
            "octocorp.ghe.com:8443",
            "user@octocorp.ghe.com",
            "octocorp.ghe.com?x=1",
            "a.b.ghe.com",
            "ghe.com",
            ".ghe.com",
            "-octo.ghe.com",
            "octo-.ghe.com",
            "github.example.com",
            "api.github.com",
            "octocorp.ghe.com.evil.test",
            "oct\u{00F6}corp.ghe.com",
            String(repeating: "a", count: 64) + ".ghe.com",
        ]
        for raw in rejected {
            XCTAssertNil(GitHubHost(raw), raw)
        }
    }
}
