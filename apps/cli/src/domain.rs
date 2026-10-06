use crate::error::ProviderError;
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

#[derive(Clone, Debug, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(transparent)]
pub struct ProviderId(pub String);

/// Identity asserted by an authenticated provider response, never inferred from a label/token hash.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct VerifiedIdentity {
    pub subject: String,
    pub tenant: Option<String>,
}
impl VerifiedIdentity {
    pub fn is_valid(&self) -> bool {
        let valid = |value: &str| {
            !value.is_empty()
                && value.len() <= 512
                && value.trim() == value
                && !value.chars().any(char::is_control)
        };
        valid(&self.subject) && self.tenant.as_deref().is_none_or(valid)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct AccountIdentity {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verified: Option<VerifiedIdentity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subscription_status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    pub id: String,
    pub label: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Quota {
    Disabled,
    Limit {
        amount: f64,
        unit: String,
    },
    Unlimited,
    Unknown,
    Available {
        used_percent: f64,
        remaining_percent: f64,
    },
    Exhausted {
        used_percent: f64,
        remaining_percent: f64,
    },
}
impl Quota {
    pub fn from_used(used: Option<f64>) -> Self {
        match used.filter(|v| v.is_finite()) {
            None => Self::Unknown,
            Some(v) => {
                let used = v.clamp(0.0, 100.0);
                if used == 100.0 {
                    Self::Exhausted {
                        used_percent: used,
                        remaining_percent: 0.0,
                    }
                } else {
                    Self::Available {
                        used_percent: used,
                        remaining_percent: 100.0 - used,
                    }
                }
            }
        }
    }
    pub fn is_valid(&self) -> bool {
        match *self {
            Self::Unknown | Self::Unlimited | Self::Disabled => true,
            Self::Limit { amount, ref unit } => {
                amount.is_finite()
                    && amount > 0.0
                    && !unit.trim().is_empty()
                    && unit.len() <= 32
                    && !unit.chars().any(char::is_control)
            }
            Self::Available {
                used_percent,
                remaining_percent,
            } => {
                used_percent.is_finite()
                    && remaining_percent.is_finite()
                    && (0.0..100.0).contains(&used_percent)
                    && remaining_percent > 0.0
                    && remaining_percent <= 100.0
                    && (used_percent + remaining_percent - 100.0).abs() < 1e-9
            }
            Self::Exhausted {
                used_percent,
                remaining_percent,
            } => used_percent == 100.0 && remaining_percent == 0.0,
        }
    }
    pub fn from_remaining(remaining: Option<f64>) -> Self {
        Self::from_used(remaining.map(|v| 100.0 - v))
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Confidence {
    Exact,
    Estimated,
    Unknown,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Provenance {
    pub source: String,
    pub confidence: Confidence,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct QuotaAmounts {
    pub remaining: f64,
    pub limit: Option<f64>,
    pub unit: String,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct Consumption {
    pub used: f64,
    pub unit: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct QuotaWindow {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metric_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub consumption: Option<Consumption>,
    pub label: String,
    pub quota: Quota,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub amounts: Option<QuotaAmounts>,
    #[serde(with = "time::serde::rfc3339::option")]
    pub resets_at: Option<OffsetDateTime>,
    /// Source-provided reset information when an exact timestamp is unavailable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reset_description: Option<String>,
    pub provenance: Provenance,
    #[serde(with = "time::serde::rfc3339")]
    pub fetched_at: OffsetDateTime,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AccountOrigin {
    BorrowedNative,
    Owned,
    BorrowedProxy,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct AccountRef {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<AccountOrigin>,
    pub id: String,
    pub label: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct UsageDiagnostic {
    pub source: String,
    pub code: ProviderError,
}
/// Banked Codex quota resets, not monetary credits. Counts are observations,
/// never a guarantee that a credit has not since been redeemed elsewhere.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ResetCredits {
    pub available_count: u64,
    #[serde(with = "time::serde::rfc3339::option")]
    pub earliest_expires_at: Option<OffsetDateTime>,
    #[serde(with = "time::serde::rfc3339")]
    pub fetched_at: OffsetDateTime,
    pub source: String,
}
impl ResetCredits {
    pub fn valid_at(&self, now: OffsetDateTime) -> bool {
        now >= self.fetched_at && self.earliest_expires_at.is_none_or(|at| at > now)
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ProviderUsage {
    #[serde(skip)]
    pub fresh_observation: bool,
    #[serde(skip)]
    pub history_identity: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reset_credits: Option<ResetCredits>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub antigravity_subscription: Option<AntigravitySubscriptionInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_profile: Option<CodexProfileAnalytics>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_reset_credits: Option<CodexResetCreditInventory>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub diagnostics: Vec<UsageDiagnostic>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account_ref: Option<AccountRef>,
    pub provider: ProviderId,
    pub account: AccountIdentity,
    pub windows: Vec<QuotaWindow>,
}
impl ProviderUsage {
    pub fn has_observations(&self) -> bool {
        !self.windows.is_empty()
            || self
                .account
                .plan
                .as_ref()
                .is_some_and(|plan| !plan.trim().is_empty())
    }
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CodexProfileAnalytics {
    pub daily_usage: Vec<CodexDailyUsage>,
    /// Sum of the latest 30 supplied buckets, not a 30-calendar-day interval.
    pub latest_30_buckets_tokens: u64,
    pub lifetime_tokens: Option<u64>,
    pub peak_daily_tokens: Option<u64>,
    pub longest_running_turn_seconds: Option<u64>,
    pub current_streak_days: Option<u64>,
    pub longest_streak_days: Option<u64>,
    #[serde(with = "time::serde::rfc3339")]
    pub fetched_at: OffsetDateTime,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CodexDailyUsage {
    pub date: String,
    pub tokens: u64,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CodexResetCreditInventory {
    pub available_count: u64,
    pub credits: Vec<CodexResetCredit>,
    #[serde(with = "time::serde::rfc3339")]
    pub fetched_at: OffsetDateTime,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CodexResetCredit {
    pub id: String,
    #[serde(with = "time::serde::rfc3339::option")]
    pub expires_at: Option<OffsetDateTime>,
}
#[derive(Clone, Debug, Serialize)]
pub struct ProviderFailure {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account_ref: Option<AccountRef>,
    pub provider: ProviderId,
    pub code: ProviderError,
    pub message: String,
}
#[derive(Clone, Debug, Serialize)]
pub struct UsageReport {
    pub schema_version: u32,
    #[serde(with = "time::serde::rfc3339")]
    pub generated_at: OffsetDateTime,
    pub providers: Vec<ProviderUsage>,
    pub failures: Vec<ProviderFailure>,
}
impl UsageReport {
    pub(crate) fn include_diagnostics(&mut self) {
        for usage in &self.providers {
            for diagnostic in &usage.diagnostics {
                if !self.failures.iter().any(|failure| {
                    failure.provider == usage.provider
                        && failure.account_ref.as_ref().map(|a| &a.id)
                            == usage.account_ref.as_ref().map(|a| &a.id)
                        && failure.code == diagnostic.code
                }) {
                    self.failures.push(ProviderFailure {
                        provider: usage.provider.clone(),
                        account_ref: usage.account_ref.clone(),
                        code: diagnostic.code,
                        message: diagnostic.code.to_string(),
                    });
                }
            }
        }
    }
    pub fn exit_code(&self) -> u8 {
        if self.providers.is_empty() {
            3
        } else if self.failures.is_empty() {
            0
        } else {
            1
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct AntigravitySubscriptionInfo {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_tier: Option<AntigravitySubscriptionTier>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paid_tier: Option<AntigravitySubscriptionTier>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub allowed_tiers: Option<Vec<AntigravitySubscriptionTier>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cloudaicompanion_project: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gcp_managed: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upgrade_subscription_uri: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct AntigravitySubscriptionTier {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub privacy_notice: Option<AntigravityPrivacyNotice>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_default: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upgrade_subscription_uri: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upgrade_subscription_text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub upgrade_subscription_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user_defined_cloudaicompanion_project: Option<bool>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct AntigravityPrivacyNotice {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub show_notice: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notice_text: Option<String>,
}
