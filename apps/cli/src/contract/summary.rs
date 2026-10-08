//! Host-owned quota summaries shared by every client.
use crate::domain::{ProviderUsage, Quota, QuotaWindow};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Totals {
    pub lowest: Option<f64>,
    pub average: Option<f64>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SummaryMetric {
    pub display_name: String,
    pub remaining_percent: Option<f64>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Summary {
    pub session_only: Totals,
    pub combined: Totals,
    pub pair: Vec<SummaryMetric>,
}
fn remaining(window: &QuotaWindow) -> Option<f64> {
    match window.quota {
        Quota::Available {
            remaining_percent, ..
        }
        | Quota::Exhausted {
            remaining_percent, ..
        } => Some(remaining_percent),
        _ => None,
    }
}
fn totals(windows: &[&QuotaWindow]) -> Totals {
    let values: Vec<_> = windows
        .iter()
        .filter_map(|window| remaining(window))
        .collect();
    Totals {
        lowest: values.iter().copied().reduce(f64::min),
        average: (!values.is_empty()).then(|| values.iter().sum::<f64>() / values.len() as f64),
    }
}
fn combine(left: Option<f64>, right: Option<f64>) -> Option<f64> {
    match (left, right) {
        (Some(a), Some(b)) => Some(a.max(b)),
        _ => left.or(right),
    }
}
pub(super) fn project(usage: &ProviderUsage) -> Summary {
    let (extra, session): (Vec<_>, Vec<_>) = usage.windows.iter().partition(|window| {
        matches!(
            window.metric_id.as_deref(),
            Some("extra-usage" | "codex-extra-usage" | "on-demand")
        ) || matches!(window.label.as_str(), "Extra usage" | "On demand")
    });
    let session = totals(&session);
    let extra = totals(&extra);
    Summary {
        session_only: Totals {
            lowest: session.lowest.or(extra.lowest),
            average: session.average.or(extra.average),
        },
        combined: Totals {
            lowest: combine(session.lowest, extra.lowest),
            average: combine(session.average, extra.average),
        },
        pair: pair(usage),
    }
}
fn pair(usage: &ProviderUsage) -> Vec<SummaryMetric> {
    let (top, bottom, require_both): (&str, &str, bool) = match usage.provider.0.as_str() {
        "claude" => ("Session", "Weekly", true),
        "codex" | "antigravity" => ("Session", "Weekly", false),
        "devin-desktop" => ("Daily", "Weekly", true),
        "amp" => ("Agent", "Orb", true),
        "cursor" => ("Plan usage", "On demand", true),
        "factory" => ("Standard Weekly", "Core Weekly", true),
        _ => return vec![],
    };
    let group = |name: &str| -> Vec<&QuotaWindow> {
        usage
            .windows
            .iter()
            .filter(|window| {
                if usage.provider.0 == "claude" && name == "Weekly" {
                    return window.label == name;
                }
                if usage.provider.0 == "amp" {
                    return window.metric_id.as_deref()
                        == Some(if name == "Agent" {
                            "amp-agent-usage"
                        } else {
                            "amp-orb-usage"
                        });
                }
                if usage.provider.0 == "factory" {
                    return window.metric_id.as_deref()
                        == Some(if name == "Standard Weekly" {
                            "factory-standard-weekly"
                        } else {
                            "factory-core-weekly"
                        });
                }
                window.label == name
                    || window
                        .label
                        .to_ascii_lowercase()
                        .ends_with(&format!(" {}", name.to_ascii_lowercase()))
            })
            .collect()
    };
    let first = group(top);
    let second = group(bottom);
    if first.is_empty() && second.is_empty()
        || require_both && (first.is_empty() || second.is_empty())
        || matches!(usage.provider.0.as_str(), "claude" | "codex")
            && totals(&first).lowest.is_none()
        || usage.provider.0 == "claude" && totals(&second).lowest.is_none()
        || usage.provider.0 == "cursor"
            && !second.iter().any(|w| {
                w.amounts
                    .as_ref()
                    .is_some_and(|a| a.limit.is_some_and(|limit| limit > 0.0))
                    && remaining(w).is_some()
            })
    {
        return vec![];
    }
    vec![
        SummaryMetric {
            display_name: top.into(),
            remaining_percent: totals(&first).lowest,
        },
        SummaryMetric {
            display_name: bottom.into(),
            remaining_percent: totals(&second).lowest,
        },
    ]
}

impl Summary {
    pub(super) fn is_valid(&self) -> bool {
        let valid =
            |value: Option<f64>| value.is_none_or(|n| n.is_finite() && (0.0..=100.0).contains(&n));
        valid(self.session_only.lowest)
            && valid(self.session_only.average)
            && valid(self.combined.lowest)
            && valid(self.combined.average)
            && (self.pair.is_empty() || self.pair.len() == 2)
            && self.pair.iter().all(|metric| {
                !metric.display_name.trim().is_empty()
                    && metric.display_name.len() <= 512
                    && !metric.display_name.chars().any(char::is_control)
                    && valid(metric.remaining_percent)
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn summaries_own_group_selection_and_unknown_values() {
        let mut usage = crate::cli::Provider::Mock
            .adapter()
            .fetch(&crate::providers::http::fixture::context())
            .await
            .unwrap();
        let template = usage.windows[0].clone();
        let window = |label: &str, remaining: Option<f64>| {
            let mut value = template.clone();
            value.label = label.into();
            value.metric_id = None;
            value.quota = Quota::from_remaining(remaining);
            value
        };
        for provider in ["claude", "codex", "antigravity"] {
            usage.provider.0 = provider.into();
            usage.windows = vec![
                window("Session", None),
                window("Spark Session", Some(38.0)),
                window("Weekly", Some(60.0)),
                window("Sonnet weekly", Some(12.0)),
            ];
            let summary = project(&usage);
            assert!(summary.is_valid());
            assert_eq!(summary.pair[0].remaining_percent, Some(38.0));
            assert_eq!(
                summary.pair[1].remaining_percent,
                Some(if provider == "claude" { 60.0 } else { 12.0 })
            );
            assert_eq!(summary.session_only.lowest, Some(12.0));
            assert_eq!(summary.session_only.average, Some(110.0 / 3.0));
        }
        usage.provider.0 = "claude".into();
        usage.windows = vec![
            window("Session", Some(80.0)),
            window("Fable", Some(60.0)),
            window("Sonnet weekly", Some(12.0)),
        ];
        assert!(project(&usage).pair.is_empty());
        usage.windows.push(window("Weekly", Some(40.0)));
        assert_eq!(project(&usage).pair[1].remaining_percent, Some(40.0));
        usage.windows.last_mut().unwrap().quota = Quota::Unknown;
        assert!(project(&usage).pair.is_empty());
        usage.provider.0 = "codex".into();
        usage.windows = vec![window("Weekly", Some(40.0))];
        assert!(project(&usage).pair.is_empty());
        usage.provider.0 = "devin-desktop".into();
        assert!(project(&usage).pair.is_empty());
        usage.windows.push(window("Daily", Some(80.0)));
        assert_eq!(project(&usage).pair.len(), 2);
        usage.provider.0 = "future-provider".into();
        usage.windows.push(window("Extra usage", Some(90.0)));
        let summary = project(&usage);
        assert!(summary.pair.is_empty());
        assert_eq!(summary.session_only.lowest, Some(40.0));
        assert_eq!(summary.combined.lowest, Some(90.0));
        usage.windows = vec![window("Unknown", None)];
        assert_eq!(project(&usage).combined.lowest, None);
        usage.provider.0 = "amp".into();
        let mut agent = window("Kilowatt agent subscription", Some(64.0));
        agent.metric_id = Some("amp-agent-usage".into());
        let mut orb = window("Kilowatt orb subscription", Some(98.0));
        orb.metric_id = Some("amp-orb-usage".into());
        usage.windows = vec![agent, orb];
        assert_eq!(project(&usage).pair[1].remaining_percent, Some(98.0));
        usage.windows.pop();
        assert!(project(&usage).pair.is_empty());
        usage.provider.0 = "cursor".into();
        usage.windows = vec![
            window("Plan usage", Some(80.0)),
            window("On demand", Some(25.0)),
        ];
        usage.windows[1].amounts = None;
        assert!(project(&usage).pair.is_empty());
        usage.windows[1].amounts = Some(crate::domain::QuotaAmounts {
            remaining: 25.0,
            limit: Some(100.0),
            unit: "units".into(),
        });
        assert_eq!(project(&usage).pair[1].remaining_percent, Some(25.0));
        usage.provider.0 = "factory".into();
        let mut standard = window("Standard weekly", Some(0.0));
        standard.metric_id = Some("factory-standard-weekly".into());
        let mut core = window("Droid Core weekly", Some(16.0));
        core.metric_id = Some("factory-core-weekly".into());
        usage.windows = vec![standard, core];
        let summary = project(&usage);
        assert_eq!(summary.pair[0].display_name, "Standard Weekly");
        assert_eq!(summary.pair[0].remaining_percent, Some(0.0));
        assert_eq!(summary.pair[1].display_name, "Core Weekly");
        assert_eq!(summary.pair[1].remaining_percent, Some(16.0));
    }
}
