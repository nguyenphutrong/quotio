use crate::{
    accounts::{AccountError, Credential, github_host::GitHubHost},
    providers::{ProviderContext, http},
};
use serde::Deserialize;

const CLIENT_ID: &str = "Iv1.b507a08c87ecfe98";
pub(super) struct Endpoints {
    pub host: GitHubHost,
    pub device: String,
    pub token: String,
    pub verification: String,
    pub profile: String,
}
impl Endpoints {
    /// Every route is derived from one validated host; callers cannot supply paths.
    pub fn for_host(host: GitHubHost) -> Self {
        Self {
            device: host.web_url("/login/device/code"),
            token: host.web_url("/login/oauth/access_token"),
            verification: host.web_url("/login/device"),
            profile: host.api_url("/user"),
            host,
        }
    }
}
impl Default for Endpoints {
    fn default() -> Self {
        Self::for_host(GitHubHost::github_com())
    }
}
#[derive(Deserialize)]
pub(super) struct Device {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub expires_in: u64,
    #[serde(default = "default_interval")]
    pub interval: u64,
}
fn default_interval() -> u64 {
    5
}
pub(super) async fn begin(
    context: &ProviderContext,
    endpoints: &Endpoints,
) -> Result<Device, AccountError> {
    let device: Device = http::json(
        context
            .http
            .post(&endpoints.device)
            .header("Accept", "application/json")
            .form(&[("client_id", CLIENT_ID), ("scope", "read:user")]),
        context.clock.now(),
    )
    .await?;
    if device.device_code.is_empty()
        || device.device_code.len() > 8192
        || device.user_code.is_empty()
        || device.user_code.len() > 128
        || device.user_code.chars().any(char::is_control)
        || device.verification_uri != endpoints.verification
        || !(1..=3600).contains(&device.expires_in)
        || device.interval > 3600
    {
        return Err(AccountError::OAuth);
    }
    Ok(device)
}
pub(super) enum Poll {
    Pending,
    SlowDown,
    Expired,
    Denied,
    Token(String),
}
#[derive(Deserialize)]
struct Response {
    access_token: Option<String>,
    error: Option<String>,
}
pub(super) async fn poll(
    context: &ProviderContext,
    endpoint: &str,
    device_code: &str,
) -> Result<Poll, AccountError> {
    let response: Response = http::json(
        context
            .http
            .post(endpoint)
            .header("Accept", "application/json")
            .form(&[
                ("client_id", CLIENT_ID),
                ("device_code", device_code),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ]),
        context.clock.now(),
    )
    .await?;
    match (response.access_token, response.error.as_deref()) {
        (Some(token), None)
            if !token.is_empty()
                && token.len() <= 16384
                && !token.chars().any(char::is_control) =>
        {
            Ok(Poll::Token(token))
        }
        (None, Some("authorization_pending")) => Ok(Poll::Pending),
        (None, Some("slow_down")) => Ok(Poll::SlowDown),
        (None, Some("expired_token")) => Ok(Poll::Expired),
        (None, Some("access_denied")) => Ok(Poll::Denied),
        _ => Err(AccountError::OAuth),
    }
}
pub(super) async fn credential(
    context: &ProviderContext,
    endpoints: &Endpoints,
    token: String,
) -> Result<Credential, AccountError> {
    #[derive(Deserialize)]
    struct Profile {
        login: String,
        id: u64,
    }
    let profile: Profile = http::json(
        context
            .http
            .get(&endpoints.profile)
            .bearer_auth(&token)
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "Quotio"),
        context.clock.now(),
    )
    .await?;
    if profile.id == 0
        || profile.login.is_empty()
        || profile.login.len() > 80
        || profile.login.chars().any(char::is_control)
    {
        return Err(AccountError::OAuth);
    }
    Ok(Credential::CopilotOAuth {
        access_token: token,
        account_id: profile.id.to_string(),
        login: profile.login,
        // Keep GitHub.com credentials byte-compatible with earlier vault entries.
        host: (!endpoints.host.is_github_com()).then(|| endpoints.host.clone()),
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn fixture_endpoints(url: &str, host: GitHubHost) -> Endpoints {
        Endpoints {
            device: url.into(),
            token: url.into(),
            profile: url.into(),
            ..Endpoints::for_host(host)
        }
    }
    #[test]
    fn endpoints_derive_from_the_selected_host_only() {
        let default = Endpoints::default();
        assert_eq!(default.device, "https://github.com/login/device/code");
        assert_eq!(default.token, "https://github.com/login/oauth/access_token");
        assert_eq!(default.verification, "https://github.com/login/device");
        assert_eq!(default.profile, "https://api.github.com/user");
        let enterprise = Endpoints::for_host(GitHubHost::parse("octocorp.ghe.com").unwrap());
        assert_eq!(
            enterprise.device,
            "https://octocorp.ghe.com/login/device/code"
        );
        assert_eq!(
            enterprise.token,
            "https://octocorp.ghe.com/login/oauth/access_token"
        );
        assert_eq!(
            enterprise.verification,
            "https://octocorp.ghe.com/login/device"
        );
        assert_eq!(enterprise.profile, "https://api.octocorp.ghe.com/user");
    }
    #[tokio::test]
    async fn verification_uri_is_pinned_to_the_selected_host() {
        let enterprise = GitHubHost::parse("octocorp.ghe.com").unwrap();
        for (uri, ok) in [
            ("https://octocorp.ghe.com/login/device", true),
            ("https://github.com/login/device", false),
            ("https://evil.ghe.com/login/device", false),
            ("https://octocorp.ghe.com/login/device?x=1", false),
        ] {
            let (url, task) = http::fixture::server(vec![json!({"device_code":"private-device", "user_code":"PUBLIC-CODE", "verification_uri":uri, "expires_in":900})]).await;
            let endpoints = fixture_endpoints(&url, enterprise.clone());
            assert_eq!(
                begin(&http::fixture::context(), &endpoints).await.is_ok(),
                ok,
                "{uri}"
            );
            task.await.unwrap();
        }
    }
    #[tokio::test]
    async fn enterprise_credentials_record_their_host() {
        let host = GitHubHost::parse("octocorp.ghe.com").unwrap();
        let (url, task) =
            http::fixture::server(vec![json!({"login":"fixture-user","id":42})]).await;
        let credential = credential(
            &http::fixture::context(),
            &fixture_endpoints(&url, host.clone()),
            "fixture-token".into(),
        )
        .await
        .unwrap();
        assert!(
            matches!(credential, Credential::CopilotOAuth { host: Some(saved), .. } if saved == host)
        );
        task.await.unwrap();
    }
    #[tokio::test]
    async fn github_contract_and_errors_use_only_loopback() {
        let (url, task) = http::fixture::server(vec![json!({"device_code":"private-device", "user_code":"PUBLIC-CODE", "verification_uri":"https://github.com/login/device", "expires_in":900})]).await;
        let device = begin(
            &http::fixture::context(),
            &fixture_endpoints(&url, GitHubHost::github_com()),
        )
        .await
        .unwrap();
        assert_eq!(device.interval, 5);
        let requests = task.await.unwrap();
        assert!(requests[0].contains("scope=read%3Auser"));
        for error in [
            "authorization_pending",
            "slow_down",
            "expired_token",
            "access_denied",
            "unknown-private-error",
        ] {
            let (url, task) = http::fixture::server(vec![json!({"error":error})]).await;
            let result = poll(&http::fixture::context(), &url, "private-device").await;
            assert_eq!(result.is_ok(), error != "unknown-private-error");
            let requests = task.await.unwrap();
            assert!(requests[0].contains("device_code=private-device"));
            assert!(requests[0].contains("urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"));
        }
        let (url, task) =
            http::fixture::server(vec![json!({"login":"fixture-user","id":42})]).await;
        assert!(
            matches!(credential(&http::fixture::context(), &fixture_endpoints(&url, GitHubHost::github_com()), "fixture-token".into()).await.unwrap(), Credential::CopilotOAuth { account_id, host: None, .. } if account_id == "42")
        );
        assert!(task.await.unwrap()[0].contains("Bearer fixture-token"));
    }
}
