#!/usr/bin/env python3
"""
Smoke-test the remote management contract against a live Quotio/CLIProxyAPI instance.

Defaults:
  - endpoint: http://127.0.0.1:8317
  - management key: read from macOS Keychain using Quotio's local service/account

The script never prints the management key.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


LOCAL_KEYCHAIN_SERVICE = "dev.quotio.desktop.local-management"
LOCAL_KEYCHAIN_ACCOUNT = "local-management-key"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--endpoint",
        default="http://127.0.0.1:8317",
        help="Remote Quotio endpoint, with or without /v0/management",
    )
    parser.add_argument(
        "--management-key",
        default=None,
        help="Management key. If omitted, read from local macOS Keychain.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=5.0,
        help="Per-request timeout in seconds.",
    )
    return parser.parse_args()


def normalize_management_base(endpoint: str) -> str:
    url = endpoint.strip().rstrip("/")
    if url.endswith("/v0/management"):
        return url
    if url.endswith("/v0"):
        return url + "/management"
    return url + "/v0/management"


def load_management_key(explicit_key: str | None) -> str:
    if explicit_key:
        return explicit_key

    result = subprocess.run(
        [
            "security",
            "find-generic-password",
            "-s",
            LOCAL_KEYCHAIN_SERVICE,
            "-a",
            LOCAL_KEYCHAIN_ACCOUNT,
            "-w",
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=3,
    )

    key = result.stdout.strip()
    if result.returncode != 0 or not key:
        raise RuntimeError(
            "Could not read local management key from Keychain. "
            "Pass --management-key explicitly."
        )

    return key


def request_json(base_url: str, endpoint: str, key: str, timeout: float) -> tuple[int, object]:
    url = urllib.parse.urljoin(base_url + "/", endpoint.lstrip("/"))
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Connection": "close",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        payload = response.read().decode("utf-8", "replace")
        return response.status, json.loads(payload) if payload else None


def main() -> int:
    args = parse_args()
    base_url = normalize_management_base(args.endpoint)
    key = load_management_key(args.management_key)

    checks = [
        ("debug", "/debug"),
        ("api_keys", "/api-keys"),
        ("auth_files", "/auth-files"),
    ]

    print(f"base_url={base_url}")

    for label, endpoint in checks:
        try:
            status, payload = request_json(base_url, endpoint, key, args.timeout)
        except urllib.error.HTTPError as error:
            print(f"{label}=FAIL http_{error.code}")
            return 1
        except Exception as error:  # noqa: BLE001
            print(f"{label}=FAIL {error}")
            return 1

        summary: str
        if label == "api_keys" and isinstance(payload, dict):
            summary = f"count={len(payload.get('apiKeys', []))}"
        elif label == "auth_files" and isinstance(payload, dict):
            summary = f"count={len(payload.get('files', []))}"
        elif label == "debug" and isinstance(payload, dict):
            summary = f"debug={payload.get('debug')}"
        else:
            summary = "ok"

        print(f"{label}=PASS status={status} {summary}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
