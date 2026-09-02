#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_root="${ARCHITECTURE_SOURCE_ROOT:-${repository_root}/Packages/QuotioCore/Sources}"
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
direct_io='\b(UserDefaults|URLSession|FileManager|Process)\b[[:space:]]*(\.|\()|\bSec(Item|Keychain|Access|Certificate|Identity|Key|Trust)[[:alnum:]_]*[[:space:]]*\('

report_matches \
    'Domain/Application imported a UI, outer-layer, security, or third-party module' \
    "${lower_layer_forbidden_imports}" \
    "${domain}" "${application}"
report_matches \
    'Domain/Application performed direct persistence, network, process, filesystem, or Security I/O' \
    "${direct_io}" \
    "${domain}" "${application}"
report_matches \
    'Infrastructure imported Presentation' \
    '^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+QuotioPresentation([[:space:].]|$)' \
    "${infrastructure}"
report_matches \
    'Presentation imported Infrastructure or a third-party infrastructure SDK' \
    '^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(QuotioInfrastructure|Security|Sparkle|PostHog)([[:space:].]|$)' \
    "${presentation}"
report_matches \
    'Presentation performed direct persistence, network, process, filesystem, or Security I/O' \
    "${direct_io}" \
    "${presentation}"

if (( failure_count > 0 )); then
    printf 'Architecture check failed with %d violation group(s).\n' "${failure_count}" >&2
    exit 1
fi

printf 'Architecture check passed.\n'
