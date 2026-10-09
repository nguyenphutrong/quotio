//! Azure OpenAI accounting is an Azure Resource Manager Cost Management query.
//! It deliberately does not send Azure OpenAI resource keys to inference routes:
//! those keys cannot authorize resource-scoped cost reporting.

use super::{AuthKind, Definition, Setting, common};
use crate::{
    domain::QuotaWindow,
    error::ProviderError,
    providers::{FetchFuture, ProviderContext, Secret, http, process},
};
use reqwest::{
    Url,
    header::{ACCEPT, AUTHORIZATION},
};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
    time::Duration as StdDuration,
};
use time::{Duration, OffsetDateTime, format_description::well_known::Rfc3339};

const AZURE_ACCESS_TOKEN: &str = "AZURE_ACCESS_TOKEN";
const AZURE_OPENAI_RESOURCE_ID: &str = "AZURE_OPENAI_RESOURCE_ID";
const MANAGEMENT_ORIGIN: &str = "https://management.azure.com";
const MANAGEMENT_AUDIENCE: &str = "https://management.azure.com/";
const COST_MANAGEMENT_API_VERSION: &str = "2025-03-01";
const COST_PERIOD_DAYS: i64 = 30;
const MAX_COST_PAGES: usize = 8;
const MAX_COST_COLUMNS: usize = 16;
const MAX_COST_ROWS_PER_PAGE: usize = 5_000;
const MAX_NEXT_LINK_BYTES: usize = 8_192;
const MAX_CURSOR_BYTES: usize = 4_096;
const MAX_RESOURCE_ID_BYTES: usize = 1_024;
const MAX_ACCESS_TOKEN_BYTES: usize = 16_384;
const AZ_CLI_TIMEOUT: StdDuration = StdDuration::from_secs(5);

const AZURE_OPENAI_SETTINGS: &[Setting] = &[Setting {
    name: "resource_id",
    env: AZURE_OPENAI_RESOURCE_ID,
    required: true,
}];

pub const DEFINITIONS: &[Definition] = &[Definition {
    id: "azureopenai",
    name: "Azure OpenAI cost",
    key_env: AZURE_ACCESS_TOKEN,
    auth: AuthKind::OAuth,
    settings: AZURE_OPENAI_SETTINGS,
    fetch: azure_openai,
}];

fn azure_openai(context: &ProviderContext) -> FetchFuture<'_> {
    Box::pin(async move {
        let resource = AzureOpenAiResource::from_context(context)?;
        let token = azure_token(context, &resource).await?;
        let now = context.clock.now();
        let endpoint = fixed_cost_query_endpoint(&resource)?;
        let query = cost_query_definition(&resource, now)?;
        let costs = cost_query_pages(context, &endpoint, &token, &query, now).await?;
        let mut usage = common::usage(
            "azureopenai",
            &token,
            &resource.resource_id,
            cost_windows(costs, now)?,
        )?;
        usage.account.label = "Azure Entra OAuth token".into();
        Ok(usage)
    })
}

/// This is the only supported Azure OpenAI resource shape. A resource ID is a
/// filter value, not an endpoint, and the Cost Management scope is its containing
/// resource group because the Query API does not document individual-resource scope.
#[derive(Clone, Debug, Eq, PartialEq)]
struct AzureOpenAiResource {
    resource_id: String,
    subscription_id: String,
    resource_group: String,
}

impl AzureOpenAiResource {
    fn from_context(context: &ProviderContext) -> Result<Self, ProviderError> {
        let value = context
            .credentials
            .get(AZURE_OPENAI_RESOURCE_ID)
            .ok_or(ProviderError::InvalidData)?;
        Self::parse(&value.0)
    }

    fn parse(value: &str) -> Result<Self, ProviderError> {
        let value = value.trim();
        if value.is_empty()
            || value.len() > MAX_RESOURCE_ID_BYTES
            || value.chars().any(char::is_control)
        {
            return Err(ProviderError::InvalidData);
        }
        let parts: Vec<_> = value.split('/').collect();
        let [
            "",
            subscriptions,
            subscription_id,
            resource_groups,
            resource_group,
            providers,
            provider,
            accounts,
            account,
        ] = parts.as_slice()
        else {
            return Err(ProviderError::InvalidData);
        };
        if !subscriptions.eq_ignore_ascii_case("subscriptions")
            || !resource_groups.eq_ignore_ascii_case("resourceGroups")
            || !providers.eq_ignore_ascii_case("providers")
            || !provider.eq_ignore_ascii_case("Microsoft.CognitiveServices")
            || !accounts.eq_ignore_ascii_case("accounts")
            || !valid_uuid(subscription_id)
            || !valid_resource_group(resource_group)
            || !valid_cognitive_services_account(account)
        {
            return Err(ProviderError::InvalidData);
        }
        Ok(Self {
            resource_id: value.into(),
            subscription_id: (*subscription_id).into(),
            resource_group: (*resource_group).into(),
        })
    }
}

fn valid_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

fn valid_resource_group(value: &str) -> bool {
    (1..=90).contains(&value.len())
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'(' | b')')
        })
}

fn valid_cognitive_services_account(value: &str) -> bool {
    let bytes = value.as_bytes();
    (2..=64).contains(&bytes.len())
        && bytes.first().is_some_and(u8::is_ascii_alphanumeric)
        && bytes
            .iter()
            .skip(1)
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(*byte, b'.' | b'_' | b'-'))
}

fn fixed_cost_query_endpoint(resource: &AzureOpenAiResource) -> Result<Url, ProviderError> {
    let base = Url::parse(MANAGEMENT_ORIGIN).map_err(|_| ProviderError::Internal)?;
    if base.scheme() != "https"
        || base.host_str() != Some("management.azure.com")
        || base.port().is_some()
        || !base.username().is_empty()
        || base.password().is_some()
        || base.path() != "/"
        || base.query().is_some()
        || base.fragment().is_some()
    {
        return Err(ProviderError::Internal);
    }
    cost_query_endpoint(&base, resource)
}

fn cost_query_endpoint(base: &Url, resource: &AzureOpenAiResource) -> Result<Url, ProviderError> {
    let mut endpoint = base.clone();
    endpoint.set_path(&format!(
        "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.CostManagement/query",
        resource.subscription_id, resource.resource_group
    ));
    endpoint.set_query(None);
    endpoint
        .query_pairs_mut()
        .append_pair("api-version", COST_MANAGEMENT_API_VERSION);
    Ok(endpoint)
}

/// `Usage` is the documented usage-based Cost Management query type. Requiring
/// `ChargeType = Usage` prevents purchases, refunds, and reservations from being
/// reported as Azure OpenAI consumption. Currency stays grouped and is never summed
/// across units.
fn cost_query_definition(
    resource: &AzureOpenAiResource,
    now: OffsetDateTime,
) -> Result<Value, ProviderError> {
    let from = (now - Duration::days(COST_PERIOD_DAYS))
        .format(&Rfc3339)
        .map_err(|_| ProviderError::Internal)?;
    let to = now.format(&Rfc3339).map_err(|_| ProviderError::Internal)?;
    Ok(json!({
        "type": "Usage",
        "timeframe": "Custom",
        "timePeriod": { "from": from, "to": to },
        "dataset": {
            "granularity": "None",
            "aggregation": {
                "totalCost": { "name": "PreTaxCost", "function": "Sum" }
            },
            "grouping": [{ "type": "Dimension", "name": "Currency" }],
            "filter": {
                "and": [
                    {
                        "dimensions": {
                            "name": "ResourceId",
                            "operator": "In",
                            "values": [resource.resource_id]
                        }
                    },
                    {
                        "dimensions": {
                            "name": "ChargeType",
                            "operator": "In",
                            "values": ["Usage"]
                        }
                    }
                ]
            }
        }
    }))
}

/// An explicit token is authoritative: a malformed explicit value must not silently
/// switch the user to whichever Azure CLI account happens to be logged in.
async fn azure_token(
    context: &ProviderContext,
    resource: &AzureOpenAiResource,
) -> Result<Secret, ProviderError> {
    if let Some(token) = explicit_access_token(context)? {
        return Ok(token);
    }
    az_cli_token(&resource.subscription_id).await
}

fn explicit_access_token(context: &ProviderContext) -> Result<Option<Secret>, ProviderError> {
    context
        .credentials
        .get(AZURE_ACCESS_TOKEN)
        .map(|value| access_token(&value.0))
        .transpose()
}

fn access_token(raw: &str) -> Result<Secret, ProviderError> {
    let raw = raw.trim();
    let token = raw
        .get(..7)
        .filter(|prefix| prefix.eq_ignore_ascii_case("bearer "))
        .map_or(raw, |_| raw[7..].trim());
    if token.is_empty()
        || token.len() > MAX_ACCESS_TOKEN_BYTES
        || token.chars().any(char::is_control)
        || token.to_ascii_lowercase().starts_with("cookie:")
    {
        return Err(ProviderError::Authentication);
    }
    Ok(Secret(token.into()))
}

async fn az_cli_token(subscription_id: &str) -> Result<Secret, ProviderError> {
    let executable = az_executable().ok_or(ProviderError::CliNotFound)?;
    let args = [
        "account",
        "get-access-token",
        "--resource",
        MANAGEMENT_AUDIENCE,
        "--subscription",
        subscription_id,
        "--query",
        "accessToken",
        "--output",
        "tsv",
        "--only-show-errors",
    ];
    // `process::output` owns a kill-on-drop child. Timing out this future therefore
    // ends the caller wait and kills the noninteractive CLI subprocess.
    let bytes = tokio::time::timeout(AZ_CLI_TIMEOUT, process::output(&executable, &args))
        .await
        .map_err(|_| ProviderError::Unavailable)??;
    access_token_from_az_output(&bytes)
}

fn access_token_from_az_output(bytes: &[u8]) -> Result<Secret, ProviderError> {
    if bytes.len() > MAX_ACCESS_TOKEN_BYTES + 2 {
        return Err(ProviderError::Authentication);
    }
    let output = std::str::from_utf8(bytes).map_err(|_| ProviderError::Authentication)?;
    let mut lines = output.lines();
    let token = lines.next().ok_or(ProviderError::Authentication)?;
    if lines.any(|line| !line.trim().is_empty()) {
        return Err(ProviderError::Authentication);
    }
    access_token(token)
}

#[cfg(windows)]
const AZ_EXECUTABLE_NAMES: &[&str] = &["az.exe", "az.cmd", "az.bat"];
#[cfg(not(windows))]
const AZ_EXECUTABLE_NAMES: &[&str] = &["az"];

fn az_executable() -> Option<PathBuf> {
    AZ_EXECUTABLE_NAMES
        .iter()
        .find_map(|name| process::resolve_program(Path::new(name)))
}

struct CostContinuation {
    url: Url,
    cursor: String,
}

struct CostQueryPage {
    costs: BTreeMap<String, f64>,
    next_link: Option<String>,
}

async fn cost_query_pages(
    context: &ProviderContext,
    initial: &Url,
    token: &Secret,
    query: &Value,
    now: OffsetDateTime,
) -> Result<BTreeMap<String, f64>, ProviderError> {
    let authorization = http::sensitive(&format!("Bearer {}", token.0))?;
    let mut current = initial.clone();
    let mut seen_urls = BTreeSet::new();
    // `$skiptoken` is the server cursor. A rewritten URL can still point at the
    // same page, so protect the aggregate with a decoded-cursor set as well.
    let mut seen_cursors = BTreeSet::new();
    let mut costs = BTreeMap::new();

    for page in 0..MAX_COST_PAGES {
        if !seen_urls.insert(current.as_str().to_owned()) {
            return Err(ProviderError::InvalidData);
        }
        let response: Value = common::json(
            context
                .http
                .post(current.clone())
                .header(AUTHORIZATION, authorization.clone())
                .header(ACCEPT, "application/json")
                .json(query),
            now,
        )
        .await?;
        let response = parse_cost_query_page(&response)?;
        for (currency, amount) in response.costs {
            let total = costs.entry(currency).or_insert(0.0);
            *total += amount;
            if !total.is_finite() {
                return Err(ProviderError::InvalidData);
            }
        }
        let Some(next) = checked_next_link(response.next_link.as_deref(), initial)? else {
            return (!costs.is_empty())
                .then_some(costs)
                .ok_or(ProviderError::InvalidData);
        };
        if !seen_cursors.insert(next.cursor) || page + 1 == MAX_COST_PAGES {
            return Err(ProviderError::InvalidData);
        }
        current = next.url;
    }
    Err(ProviderError::InvalidData)
}

fn parse_cost_query_page(value: &Value) -> Result<CostQueryPage, ProviderError> {
    let properties = value
        .get("properties")
        .and_then(Value::as_object)
        .ok_or(ProviderError::InvalidData)?;
    let columns = properties
        .get("columns")
        .and_then(Value::as_array)
        .filter(|columns| !columns.is_empty() && columns.len() <= MAX_COST_COLUMNS)
        .ok_or(ProviderError::InvalidData)?;
    let mut pre_tax_cost = None;
    let mut currency = None;
    for (index, column) in columns.iter().enumerate() {
        let column = column.as_object().ok_or(ProviderError::InvalidData)?;
        let name = column
            .get("name")
            .and_then(Value::as_str)
            .ok_or(ProviderError::InvalidData)?;
        let kind = column
            .get("type")
            .and_then(Value::as_str)
            .ok_or(ProviderError::InvalidData)?;
        match name {
            "PreTaxCost" if kind == "Number" => {
                if pre_tax_cost.replace(index).is_some() {
                    return Err(ProviderError::InvalidData);
                }
            }
            "Currency" if kind == "String" && currency.replace(index).is_some() => {
                return Err(ProviderError::InvalidData);
            }
            _ => (),
        }
    }
    let pre_tax_cost = pre_tax_cost.ok_or(ProviderError::InvalidData)?;
    let currency = currency.ok_or(ProviderError::InvalidData)?;
    let rows = properties
        .get("rows")
        .and_then(Value::as_array)
        .filter(|rows| rows.len() <= MAX_COST_ROWS_PER_PAGE)
        .ok_or(ProviderError::InvalidData)?;
    let mut costs = BTreeMap::new();
    for row in rows {
        let row = row.as_array().ok_or(ProviderError::InvalidData)?;
        if row.len() != columns.len() {
            return Err(ProviderError::InvalidData);
        }
        let amount = common::number(row.get(pre_tax_cost))?.ok_or(ProviderError::InvalidData)?;
        let currency = currency_code(row.get(currency).ok_or(ProviderError::InvalidData)?)?;
        let total = costs.entry(currency).or_insert(0.0);
        *total += amount;
        if !total.is_finite() {
            return Err(ProviderError::InvalidData);
        }
    }
    let next_link = match properties.get("nextLink") {
        None | Some(Value::Null) => None,
        Some(Value::String(value)) => Some(value.into()),
        Some(_) => return Err(ProviderError::InvalidData),
    };
    Ok(CostQueryPage { costs, next_link })
}

fn currency_code(value: &Value) -> Result<String, ProviderError> {
    let value = value.as_str().ok_or(ProviderError::InvalidData)?;
    if value.len() != 3 || !value.bytes().all(|byte| byte.is_ascii_uppercase()) {
        return Err(ProviderError::InvalidData);
    }
    Ok(value.into())
}

/// Azure sends a complete continuation URL. It may use a service-selected API
/// version, so retain its query verbatim, but never forward the bearer token unless
/// it has the same authority and Cost Management query path as the original request.
fn checked_next_link(
    raw: Option<&str>,
    initial: &Url,
) -> Result<Option<CostContinuation>, ProviderError> {
    let Some(raw) = raw else {
        return Ok(None);
    };
    if raw.is_empty()
        || raw.len() > MAX_NEXT_LINK_BYTES
        || raw.trim() != raw
        || raw.chars().any(char::is_control)
    {
        return Err(ProviderError::InvalidData);
    }
    let next = Url::parse(raw).map_err(|_| ProviderError::InvalidData)?;
    let same_host = initial
        .host_str()
        .zip(next.host_str())
        .is_some_and(|(left, right)| left.eq_ignore_ascii_case(right));
    if next.scheme() != initial.scheme()
        || !same_host
        || next.port_or_known_default() != initial.port_or_known_default()
        || !next.username().is_empty()
        || next.password().is_some()
        || next.fragment().is_some()
        || !next.path().eq_ignore_ascii_case(initial.path())
    {
        return Err(ProviderError::InvalidData);
    }
    let mut cursor = None;
    for (name, value) in next.query_pairs() {
        if name == "$skiptoken"
            && (value.is_empty()
                || value.len() > MAX_CURSOR_BYTES
                || value.chars().any(char::is_control)
                || cursor.replace(value.into_owned()).is_some())
        {
            return Err(ProviderError::InvalidData);
        }
    }
    let cursor = cursor.ok_or(ProviderError::InvalidData)?;
    Ok(Some(CostContinuation { url: next, cursor }))
}

fn cost_windows(
    costs: BTreeMap<String, f64>,
    now: OffsetDateTime,
) -> Result<Vec<QuotaWindow>, ProviderError> {
    if costs.is_empty() {
        return Err(ProviderError::InvalidData);
    }
    costs
        .into_iter()
        .map(|(currency, cost)| {
            common::window(
                &format!("Azure OpenAI usage cost ({currency})"),
                Some(cost),
                None,
                None,
                &currency,
                None,
                "azure_cost_management_usage",
                now,
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::{Clock, CredentialStore, http::fixture};
    use std::{collections::BTreeMap, sync::Arc};
    use tokio::{
        io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
        net::TcpListener,
    };

    const RESOURCE_ID: &str = "/subscriptions/01234567-89ab-cdef-0123-456789abcdef/resourceGroups/azure-openai/providers/Microsoft.CognitiveServices/accounts/quotio-openai";

    struct Credentials(BTreeMap<String, String>);

    impl CredentialStore for Credentials {
        fn get(&self, name: &str) -> Option<Secret> {
            self.0.get(name).cloned().map(Secret)
        }
    }

    struct FixedClock;

    impl Clock for FixedClock {
        fn now(&self) -> OffsetDateTime {
            OffsetDateTime::parse("2026-09-05T12:00:00Z", &Rfc3339).unwrap()
        }
    }

    fn context(entries: &[(&str, &str)]) -> ProviderContext {
        let mut context = fixture::context();
        context.clock = Arc::new(FixedClock);
        context.credentials = Arc::new(Credentials(
            entries
                .iter()
                .map(|(name, value)| ((*name).into(), (*value).into()))
                .collect(),
        ));
        context
    }

    fn resource() -> AzureOpenAiResource {
        AzureOpenAiResource::parse(RESOURCE_ID).unwrap()
    }

    #[test]
    fn definition_requires_a_nonsecret_resource_id_and_uses_oauth() {
        let definition = DEFINITIONS.first().unwrap();
        assert_eq!(definition.id, "azureopenai");
        assert!(definition.auth == AuthKind::OAuth);
        assert_eq!(definition.key_env, AZURE_ACCESS_TOKEN);
        assert_eq!(definition.settings.len(), 1);
        assert_eq!(definition.settings[0].name, "resource_id");
        assert_eq!(definition.settings[0].env, AZURE_OPENAI_RESOURCE_ID);
        assert!(definition.settings[0].required);
    }

    #[test]
    fn resource_id_is_exact_cognitive_services_account_shape() {
        let resource = resource();
        assert_eq!(
            resource.subscription_id,
            "01234567-89ab-cdef-0123-456789abcdef"
        );
        assert_eq!(resource.resource_group, "azure-openai");
        for invalid in [
            "subscriptions/01234567-89ab-cdef-0123-456789abcdef/resourceGroups/azure-openai/providers/Microsoft.CognitiveServices/accounts/quotio-openai",
            "/subscriptions/not-a-uuid/resourceGroups/azure-openai/providers/Microsoft.CognitiveServices/accounts/quotio-openai",
            "/subscriptions/01234567-89ab-cdef-0123-456789abcdef/resourceGroups/azure-openai/providers/Microsoft.OpenAI/accounts/quotio-openai",
            "/subscriptions/01234567-89ab-cdef-0123-456789abcdef/resourceGroups/azure-openai/providers/Microsoft.CognitiveServices/accounts/-bad",
            "/subscriptions/01234567-89ab-cdef-0123-456789abcdef/resourceGroups/azure-openai/providers/Microsoft.CognitiveServices/accounts/quotio-openai/deployments/chat",
        ] {
            assert_eq!(
                AzureOpenAiResource::parse(invalid),
                Err(ProviderError::InvalidData)
            );
        }
    }

    #[test]
    fn query_is_explicit_resource_scoped_usage_only_and_currency_grouped() {
        let now = FixedClock.now();
        let query = cost_query_definition(&resource(), now).unwrap();
        assert_eq!(query["type"], "Usage");
        assert_eq!(query["timeframe"], "Custom");
        assert_eq!(query["timePeriod"]["from"], "2026-08-06T12:00:00Z");
        assert_eq!(query["timePeriod"]["to"], "2026-09-05T12:00:00Z");
        assert_eq!(
            query["dataset"]["aggregation"]["totalCost"]["name"],
            "PreTaxCost"
        );
        assert_eq!(query["dataset"]["grouping"][0]["name"], "Currency");
        assert_eq!(
            query["dataset"]["filter"]["and"][0]["dimensions"]["name"],
            "ResourceId"
        );
        assert_eq!(
            query["dataset"]["filter"]["and"][0]["dimensions"]["values"][0],
            RESOURCE_ID
        );
        assert_eq!(
            query["dataset"]["filter"]["and"][1]["dimensions"]["name"],
            "ChargeType"
        );
        assert_eq!(
            query["dataset"]["filter"]["and"][1]["dimensions"]["values"][0],
            "Usage"
        );
        let endpoint = fixed_cost_query_endpoint(&resource()).unwrap();
        assert_eq!(endpoint.scheme(), "https");
        assert_eq!(endpoint.host_str(), Some("management.azure.com"));
        assert_eq!(
            endpoint.path(),
            "/subscriptions/01234567-89ab-cdef-0123-456789abcdef/resourceGroups/azure-openai/providers/Microsoft.CostManagement/query"
        );
        assert_eq!(endpoint.query(), Some("api-version=2025-03-01"));
    }

    #[test]
    fn explicit_bearer_and_cli_output_tokens_are_strict() {
        let context = context(&[(AZURE_ACCESS_TOKEN, "Bearer direct-token")]);
        assert_eq!(
            explicit_access_token(&context).unwrap().unwrap().0,
            "direct-token"
        );
        assert_eq!(
            access_token_from_az_output(b"cli-token\n").unwrap().0,
            "cli-token"
        );
        for invalid in [
            b"\n".as_slice(),
            b"first\nsecond\n".as_slice(),
            b"cookie: x\n".as_slice(),
        ] {
            assert!(matches!(
                access_token_from_az_output(invalid),
                Err(ProviderError::Authentication)
            ));
        }
    }

    #[test]
    fn cost_rows_require_explicit_number_and_currency_columns() {
        let page = parse_cost_query_page(&serde_json::json!({
            "properties": {
                "columns": [
                    {"name": "PreTaxCost", "type": "Number"},
                    {"name": "Currency", "type": "String"}
                ],
                "rows": [[1.25, "USD"], [2.75, "USD"], [3, "EUR"]],
                "nextLink": null
            }
        }))
        .unwrap();
        assert_eq!(page.costs.get("USD"), Some(&4.0));
        assert_eq!(page.costs.get("EUR"), Some(&3.0));
        assert!(matches!(
            parse_cost_query_page(&serde_json::json!({
                "properties": {
                    "columns": [{"name": "PreTaxCost", "type": "Number"}],
                    "rows": [[1.0]]
                }
            })),
            Err(ProviderError::InvalidData)
        ));
        assert!(matches!(
            parse_cost_query_page(&serde_json::json!({
                "properties": {
                    "columns": [
                        {"name": "PreTaxCost", "type": "Number"},
                        {"name": "Currency", "type": "String"}
                    ],
                    "rows": [[1.0, "usd"]]
                }
            })),
            Err(ProviderError::InvalidData)
        ));
    }

    #[test]
    fn continuation_cannot_change_origin_or_query_path() {
        let initial = fixed_cost_query_endpoint(&resource()).unwrap();
        let valid = "https://management.azure.com/subscriptions/01234567-89ab-cdef-0123-456789abcdef/resourceGroups/azure-openai/providers/Microsoft.CostManagement/Query?api-version=2021-10-01&%24skiptoken=cursor";
        assert!(checked_next_link(Some(valid), &initial).unwrap().is_some());
        for invalid in [
            "https://attacker.invalid/subscriptions/01234567-89ab-cdef-0123-456789abcdef/resourceGroups/azure-openai/providers/Microsoft.CostManagement/query?%24skiptoken=cursor",
            "https://management.azure.com/subscriptions/01234567-89ab-cdef-0123-456789abcdef/providers/Microsoft.CostManagement/query?%24skiptoken=cursor",
            "https://management.azure.com/subscriptions/01234567-89ab-cdef-0123-456789abcdef/resourceGroups/azure-openai/providers/Microsoft.CostManagement/query?api-version=2025-03-01",
        ] {
            assert!(matches!(
                checked_next_link(Some(invalid), &initial),
                Err(ProviderError::InvalidData)
            ));
        }
    }

    async fn paged_server(repeat_cursor: bool) -> (Url, tokio::task::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let base = format!("http://{address}");
        let next_link = format!(
            "{base}/subscriptions/01234567-89ab-cdef-0123-456789abcdef/resourceGroups/azure-openai/providers/Microsoft.CostManagement/Query?api-version=2021-10-01&%24skiptoken=next"
        );
        let repeated_next_link = repeat_cursor.then(|| {
            format!(
                "{base}/subscriptions/01234567-89ab-cdef-0123-456789abcdef/resourceGroups/azure-openai/providers/Microsoft.CostManagement/query?%24skiptoken=%6eext&api-version=2025-03-01"
            )
        });
        let responses = vec![
            serde_json::json!({
                "properties": {
                    "columns": [
                        {"name": "PreTaxCost", "type": "Number"},
                        {"name": "Currency", "type": "String"}
                    ],
                    "rows": [[1.25, "USD"]],
                    "nextLink": next_link
                }
            }),
            serde_json::json!({
                "properties": {
                    "columns": [
                        {"name": "PreTaxCost", "type": "Number"},
                        {"name": "Currency", "type": "String"}
                    ],
                    "rows": [[2.75, "USD"], [3.0, "EUR"]],
                    "nextLink": repeated_next_link
                }
            }),
        ];
        let task = tokio::spawn(async move {
            let mut requests = Vec::new();
            for response in responses {
                let (socket, _) = listener.accept().await.unwrap();
                let mut socket = BufReader::new(socket);
                let mut request = String::new();
                let mut length = 0;
                loop {
                    let mut line = String::new();
                    socket.read_line(&mut line).await.unwrap();
                    if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                        length = value.trim().parse::<usize>().unwrap();
                    }
                    request.push_str(&line);
                    if line == "\r\n" {
                        break;
                    }
                }
                assert!(length < 4096);
                let mut body = vec![0; length];
                socket.read_exact(&mut body).await.unwrap();
                request.push_str(std::str::from_utf8(&body).unwrap());
                requests.push(request);
                let body = response.to_string();
                socket
                    .get_mut()
                    .write_all(
                        format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                            body.len()
                        )
                        .as_bytes(),
                    )
                    .await
                    .unwrap();
            }
            requests
        });
        (Url::parse(&base).unwrap(), task)
    }

    #[tokio::test]
    async fn synthetic_pages_keep_bearer_fixed_scope_and_currencies_separate() {
        let resource = resource();
        let (base, task) = paged_server(false).await;
        let context = context(&[]);
        let now = context.clock.now();
        let endpoint = cost_query_endpoint(&base, &resource).unwrap();
        let query = cost_query_definition(&resource, now).unwrap();
        let costs = cost_query_pages(
            &context,
            &endpoint,
            &Secret("synthetic-token".into()),
            &query,
            now,
        )
        .await
        .unwrap();
        assert_eq!(costs.get("USD"), Some(&4.0));
        assert_eq!(costs.get("EUR"), Some(&3.0));
        let requests = task.await.unwrap();
        assert_eq!(requests.len(), 2);
        assert!(requests.iter().all(|request| request.starts_with("POST ")));
        assert!(requests.iter().all(|request| {
            request
                .to_ascii_lowercase()
                .contains("authorization: bearer synthetic-token")
        }));
        let first_body = requests[0].split_once("\r\n\r\n").unwrap().1;
        let second_body = requests[1].split_once("\r\n\r\n").unwrap().1;
        assert_eq!(first_body, second_body);
        let body: Value = serde_json::from_str(first_body).unwrap();
        assert_eq!(
            body["dataset"]["filter"]["and"][0]["dimensions"]["values"][0],
            RESOURCE_ID
        );
        assert_eq!(
            body["dataset"]["filter"]["and"][1]["dimensions"]["values"][0],
            "Usage"
        );
        assert!(requests[1].contains("skiptoken=next"));
        assert!(
            !requests
                .iter()
                .any(|request| request.to_ascii_lowercase().contains("cookie:"))
        );
    }

    #[tokio::test]
    async fn repeated_decoded_cursor_with_changed_query_is_rejected() {
        let resource = resource();
        let (base, task) = paged_server(true).await;
        let context = context(&[]);
        let now = context.clock.now();
        let endpoint = cost_query_endpoint(&base, &resource).unwrap();
        let query = cost_query_definition(&resource, now).unwrap();
        let result = cost_query_pages(
            &context,
            &endpoint,
            &Secret("synthetic-token".into()),
            &query,
            now,
        )
        .await;
        assert!(matches!(result, Err(ProviderError::InvalidData)));
        let requests = task.await.unwrap();
        // The second response repeats the decoded cursor with a reordered query and
        // a different API version. It must be rejected before a third request can
        // add the first page again.
        assert_eq!(requests.len(), 2);
    }
}
