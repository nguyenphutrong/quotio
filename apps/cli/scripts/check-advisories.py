#!/usr/bin/env python3
"""Fail CI on OSV advisories for registry packages in Cargo.lock (Python 3.11+)."""
import argparse
import json
from pathlib import Path
import sys
import tomllib
import urllib.error
import urllib.request

# Reviewed advisories, by exact package, version and ID. A lockfile bump drops the exception.
ACCEPTED = {
    # Needs a panicking callback whose panic is caught; tern-sdk 0.1.0 only calls
    # Sha256::digest. Remove when tern-sdk moves to sha2 0.11.
    ("block-buffer", "0.10.4", "GHSA-qwgh-2vcv-g2f7"),
}


def check(lockfile: Path) -> list[dict]:
    locked = tomllib.loads(lockfile.read_text())["package"]
    public_registry = "registry+https://github.com/rust-lang/crates.io-index"
    if any(p.get("source", "").startswith("registry+") and p["source"] != public_registry for p in locked):
        raise ValueError("Non-public registry requires an explicit advisory policy")
    packages = [p for p in locked if p.get("source") == public_registry]
    queries = [
        {"package": {"ecosystem": "crates.io", "name": p["name"]}, "version": p["version"]}
        for p in packages
    ]
    request = urllib.request.Request(
        "https://api.osv.dev/v1/querybatch",
        json.dumps({"queries": queries}).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "quotio-security-check"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        body = response.read(5 * 1024 * 1024 + 1)
    if len(body) > 5 * 1024 * 1024:
        raise ValueError("OSV response too large")
    results = json.loads(body)["results"]
    if not isinstance(results, list) or len(results) != len(packages):
        raise ValueError("OSV response count does not match the lockfile")
    findings = []
    for package, result in zip(packages, results):
        vulnerabilities = result.get("vulns", [])
        if not isinstance(vulnerabilities, list):
            raise ValueError("Invalid OSV vulnerability list")
        ids = [v["id"] for v in vulnerabilities]
        if any(not isinstance(id, str) or not id for id in ids):
            raise ValueError("Invalid OSV advisory ID")
        ids = [id for id in ids if (package["name"], package["version"], id) not in ACCEPTED]
        if ids:
            findings.append({"package": package["name"], "version": package["version"], "advisories": ids})
    print(json.dumps({"packages_checked": len(packages), "findings": findings}, indent=2))
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lockfile", type=Path, default=Path("Cargo.lock"))
    args = parser.parse_args()
    try:
        return 1 if check(args.lockfile) else 0
    except (OSError, ValueError, KeyError, TypeError, AttributeError, urllib.error.URLError) as error:
        print(f"Advisory check failed ({type(error).__name__}); no clean result is claimed.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
