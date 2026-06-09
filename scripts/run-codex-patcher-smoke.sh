#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BIN="$(mktemp /tmp/quotio-codex-patcher-smoke.XXXXXX)"

cleanup() {
  rm -f "$TMP_BIN"
}
trap cleanup EXIT

cd "$ROOT_DIR"

swiftc \
  Quotio/Services/LanguageManager.swift \
  Quotio/Models/AppRuntimeIdentity.swift \
  Quotio/Models/AgentModels.swift \
  Quotio/Models/Models.swift \
  Quotio/Services/CodexConfigPatcher.swift \
  scripts/codex-patcher-smoke/main.swift \
  -o "$TMP_BIN"

"$TMP_BIN"
