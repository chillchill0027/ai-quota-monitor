#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
sources=()
for source in Sources/*.swift; do
    [ "$source" = "Sources/AppDelegate.swift" ] || sources+=("$source")
done
swiftc -target arm64-apple-macosx14.0 -sdk "$(xcrun --show-sdk-path)" -module-cache-path /tmp/swift-module-cache "${sources[@]}" Tests/AIQuotaMonitorTests/*.swift -o "$test_dir/quota-tests"
"$test_dir/quota-tests"
