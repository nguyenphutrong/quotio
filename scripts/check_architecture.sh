#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_root="${ARCHITECTURE_SOURCE_ROOT:-${repository_root}/Packages/QuotioCore/Sources}"
app_root="${ARCHITECTURE_APP_ROOT:-${repository_root}/Quotio}"
app_test_root="${ARCHITECTURE_APP_TEST_ROOT:-${repository_root}/QuotioTests}"
failure_count=0

report_matches() {
    local description="$1"
    local pattern="$2"
    shift 2

    local matches
    if matches="$(rg --line-number --glob '*.swift' "${pattern}" "$@")"; then
        printf 'Architecture violation: %s\n%s\n' "${description}" "${matches}" >&2
        failure_count=$((failure_count + 1))
    fi
}

report_files() {
    local description="$1"
    local files="$2"

    if [[ -n "${files}" ]]; then
        printf 'Architecture violation: %s\n%s\n' "${description}" "${files}" >&2
        failure_count=$((failure_count + 1))
    fi
}

unexpected_app_sources() {
    local file relative_path
    while IFS= read -r file; do
        relative_path="${file#${app_root}/}"
        case "${relative_path}" in
            QuotioApp.swift|App/*.swift) ;;
            *) printf '%s\n' "${file}" ;;
        esac
    done < <(rg --files --glob '*.swift' "${app_root}" 2>/dev/null || true)
}

unexpected_app_tests() {
    local file
    while IFS= read -r file; do
        case "$(basename "${file}")" in
            AppIdentityTests.swift|AppRuntimeTests.swift|LocalizationBundleTests.swift) ;;
            *) printf '%s\n' "${file}" ;;
        esac
    done < <(rg --files --glob '*.swift' "${app_test_root}" 2>/dev/null || true)
}

domain="${source_root}/QuotioDomain"
application="${source_root}/QuotioApplication"
infrastructure="${source_root}/QuotioInfrastructure"
presentation="${source_root}/QuotioPresentation"

for directory in "${domain}" "${application}" "${infrastructure}" "${presentation}"; do
    if [[ ! -d "${directory}" ]]; then
        printf 'Architecture check cannot find source directory: %s\n' "${directory}" >&2
        exit 2
    fi
done

lower_layer_forbidden_imports='^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(SwiftUI|AppKit|Observation|QuotioInfrastructure|QuotioPresentation|Security|Sparkle|PostHog)([[:space:].]|$)'
direct_io='\b(UserDefaults|URLSession|FileManager|FileHandle|Process)\b[[:space:]]*(\.|\()|\bData[[:space:]]*\([[:space:]]*contentsOf:|\bSec(Item|Keychain|Access|Certificate|Identity|Key|Trust)[[:alnum:]_]*[[:space:]]*\('
temporary_bridge_symbols='\b(LegacyAppRuntimeServices|CustomProviderTransportError|AIProvider|MonitorAccount|MonitorAccountSource|ModelQuota|ProviderQuotaData|SubscriptionTier|PrivacyNotice|SubscriptionInfo)\b'
cross_module_typealias='^[[:space:]]*public[[:space:]]+typealias[[:space:]]+[[:alnum:]_]+[[:space:]]*=[[:space:]]*Quotio(Domain|Application|Infrastructure|Presentation)\.'
first_party_singleton='\bstatic[[:space:]]+(let|var)[[:space:]]+shared\b'

report_matches \
    'Domain/Application imported a UI, outer-layer, security, or third-party module' \
    "${lower_layer_forbidden_imports}" \
    "${domain}" "${application}"
report_matches \
    'Domain/Application performed direct persistence, network, process, filesystem, or Security I/O' \
    "${direct_io}" \
    "${domain}" "${application}"
report_matches \
    'Domain/Application resolved user-facing localization' \
    '\.localized(Static)?[[:space:]]*\(' \
    "${domain}" "${application}"
report_matches \
    'Domain/Application declared UI-ready LocalizedError text' \
    '\bLocalizedError\b' \
    "${domain}" "${application}"
report_matches \
    'Infrastructure imported Presentation' \
    '^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+QuotioPresentation([[:space:].]|$)' \
    "${infrastructure}"
report_matches \
    'Agent adapters depend on presentation localization' \
    '\bAgentTextLocalizer\b|\blocalize[[:space:]]*:' \
    "${application}/Agents" "${infrastructure}/Agents"
report_matches \
    'Presentation imported Infrastructure or a third-party infrastructure SDK' \
    '^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(QuotioInfrastructure|Security|Sparkle|PostHog)([[:space:].]|$)' \
    "${presentation}"
report_matches \
    'Presentation performed direct persistence, network, process, filesystem, or Security I/O' \
    "${direct_io}" \
    "${presentation}"
report_matches \
    'Presentation accessed workspace or pasteboard side effects directly' \
    '\b(NSWorkspace|NSPasteboard)\b' \
    "${presentation}"

report_files \
    'Executable Swift source exists outside QuotioApp.swift or Quotio/App' \
    "$(unexpected_app_sources)"

report_files \
    'Package-owned unit test remains in the executable test target' \
    "$(unexpected_app_tests)"

report_matches \
    'Temporary migration bridge symbol remains in production source' \
    "${temporary_bridge_symbols}" \
    "${source_root}" "${app_root}"
report_matches \
    'Public cross-module typealias re-exports an outer module value' \
    "${cross_module_typealias}" \
    "${source_root}" "${app_root}"
report_matches \
    'First-party singleton declaration remains in production source' \
    "${first_party_singleton}" \
    "${source_root}" "${app_root}"
report_matches \
    'Executable source outside CompositionRoot imported or qualified Infrastructure' \
    '^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+QuotioInfrastructure([[:space:].]|$)|\bQuotioInfrastructure\.' \
    --glob '!**/App/CompositionRoot.swift' \
    "${app_root}"

if (( failure_count > 0 )); then
    printf 'Architecture check failed with %d violation group(s).\n' "${failure_count}" >&2
    exit 1
fi

printf 'Architecture check passed.\n'
