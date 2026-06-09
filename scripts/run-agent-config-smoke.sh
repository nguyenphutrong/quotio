#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BIN="$(mktemp /tmp/quotio-agent-config-smoke.XXXXXX)"
TMP_HOME="$(mktemp -d /tmp/quotio-agent-config-home.XXXXXX)"

cleanup() {
  rm -f "$TMP_BIN"
  rm -rf "$TMP_HOME"
}
trap cleanup EXIT

cd "$ROOT_DIR"

swiftc \
  Quotio/Services/LanguageManager.swift \
  Quotio/Models/AppRuntimeIdentity.swift \
  Quotio/Models/AgentModels.swift \
  Quotio/Models/Models.swift \
  Quotio/Services/CodexConfigPatcher.swift \
  Quotio/Services/AgentDetectionService.swift \
  Quotio/Services/ProxyConfigurationService.swift \
  Quotio/Services/AgentConfigurationService.swift \
  scripts/agent-config-smoke/main.swift \
  -o "$TMP_BIN"

QUOTIO_AGENT_CONFIG_SMOKE_HOME="$TMP_HOME" "$TMP_BIN"
