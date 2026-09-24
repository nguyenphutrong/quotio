//! GitHub host selection for Copilot device authorization.
//!
//! Only GitHub.com and GitHub Enterprise Cloud with data residency (`*.ghe.com`)
//! are accepted. Self-hosted GitHub Enterprise Server requires an OAuth app
//! registered on that instance, so an arbitrary host is deliberately rejected
//! instead of sending a device code or token to an unverified origin.

use serde::{Deserialize, Serialize};

const DEFAULT: &str = "github.com";
const DATA_RESIDENCY_SUFFIX: &str = ".ghe.com";

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct GitHubHost(String);

#[derive(Debug, PartialEq, Eq)]
pub struct InvalidGitHubHost;

impl GitHubHost {
    /// Accepts a bare, lowercase-insensitive host name only. URLs, ports, paths,
    /// credentials and nested subdomains are rejected rather than normalized.
    pub fn parse(raw: &str) -> Result<Self, InvalidGitHubHost> {
        if raw.is_empty() || raw.len() > 253 || !raw.is_ascii() {
            return Err(InvalidGitHubHost);
        }
        let host = raw.to_ascii_lowercase();
        if host == DEFAULT {
            return Ok(Self(host));
        }
        let subdomain = host
            .strip_suffix(DATA_RESIDENCY_SUFFIX)
            .ok_or(InvalidGitHubHost)?;
        let valid = !subdomain.is_empty()
            && subdomain.len() <= 63
            && !subdomain.starts_with('-')
            && !subdomain.ends_with('-')
            && subdomain
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
        if !valid {
            return Err(InvalidGitHubHost);
        }
        Ok(Self(host))
    }
    pub fn github_com() -> Self {
        Self(DEFAULT.into())
    }
    pub fn is_github_com(&self) -> bool {
        self.0 == DEFAULT
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
    /// Browser and OAuth routes live on the host itself.
    pub fn web_url(&self, path: &str) -> String {
        format!("https://{}{path}", self.0)
    }
    /// REST routes live on `api.github.com` or `api.<subdomain>.ghe.com`.
    pub fn api_url(&self, path: &str) -> String {
        format!("https://api.{}{path}", self.0)
    }
}

impl TryFrom<String> for GitHubHost {
    type Error = &'static str;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        Self::parse(&value).map_err(|_| "invalid GitHub host")
    }
}

impl From<GitHubHost> for String {
    fn from(value: GitHubHost) -> Self {
        value.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_github_com_and_data_residency_hosts() {
        for (raw, host) in [
            ("github.com", "github.com"),
            ("GitHub.com", "github.com"),
            ("octocorp.ghe.com", "octocorp.ghe.com"),
            ("Octo-Corp2.GHE.com", "octo-corp2.ghe.com"),
        ] {
            assert_eq!(GitHubHost::parse(raw).unwrap().as_str(), host);
        }
    }

    #[test]
    fn rejects_urls_other_hosts_and_ambiguous_forms() {
        for raw in [
            "",
            " octocorp.ghe.com",
            "octocorp.ghe.com ",
            "https://octocorp.ghe.com",
            "octocorp.ghe.com/",
            "octocorp.ghe.com:443",
            "user@octocorp.ghe.com",
            "octocorp.ghe.com?x=1",
            "octocorp.ghe.com#x",
            "ghe.com",
            ".ghe.com",
            "-octo.ghe.com",
            "octo-.ghe.com",
            "a.b.ghe.com",
            "octo_corp.ghe.com",
            "octocorp.ghe.com.evil.test",
            "evilghe.com",
            "github.example.com",
            "api.github.com",
            "gist.github.com",
            "octocorp.ghe.com\n",
            "оctocorp.ghe.com",
        ] {
            assert!(GitHubHost::parse(raw).is_err(), "{raw:?}");
        }
        assert!(GitHubHost::parse(&format!("{}.ghe.com", "a".repeat(64))).is_err());
        assert!(GitHubHost::parse(&format!("{}.ghe.com", "a".repeat(63))).is_ok());
    }

    #[test]
    fn derives_web_and_api_routes() {
        let host = GitHubHost::parse("octocorp.ghe.com").unwrap();
        assert_eq!(
            host.web_url("/login/device"),
            "https://octocorp.ghe.com/login/device"
        );
        assert_eq!(host.api_url("/user"), "https://api.octocorp.ghe.com/user");
        let default = GitHubHost::github_com();
        assert!(default.is_github_com());
        assert_eq!(default.api_url("/user"), "https://api.github.com/user");
    }

    #[test]
    fn deserialization_revalidates_stored_hosts() {
        assert!(serde_json::from_str::<GitHubHost>("\"octocorp.ghe.com\"").is_ok());
        assert!(serde_json::from_str::<GitHubHost>("\"evil.example\"").is_err());
    }
}
