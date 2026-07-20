#!/bin/bash
# Guards the updater's signing-trust rule:
# 1. Asserts the harness's mirrored copy hasn't drifted from Updater.swift.
# 2. Runs the trust-rule harness.
set -euo pipefail
cd "$(dirname "$0")/.."

extract() {
  grep -o 'downloaded.contains("[^"]*\(\\"\)\{0,1\}[^"]*")' "$1" | sort
}

A=$(extract Sources/Sofa/Updater.swift)
B=$(extract Tests/UpdaterTrustHarness/TrustRule.swift)
if [ "$A" != "$B" ]; then
  echo "✗ Trust rule drift between Updater.swift and the test mirror:"
  diff <(echo "$A") <(echo "$B") || true
  exit 1
fi

BIN=$(mktemp /tmp/sofa-trust.XXXXXX)
swiftc -o "$BIN" Tests/UpdaterTrustHarness/main.swift Tests/UpdaterTrustHarness/TrustRule.swift
"$BIN"
rm -f "$BIN"
