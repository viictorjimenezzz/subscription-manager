#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
sources="$project_dir/Sources/QuotaManager"
test_dir="$(mktemp -d /tmp/quota-manager-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT

# Everything except the SwiftUI app and its store, so the harness builds
# with the Command Line Tools alone.
swiftc \
  "$sources/JSONValue.swift" \
  "$sources/QuotaModels.swift" \
  "$sources/ClaudeUsageParser.swift" \
  "$sources/Vault.swift" \
  "$sources/CommandLineTool.swift" \
  "$sources/QuotaBackend.swift" \
  "$sources/CodexAppServerClient.swift" \
  "$sources/ClaudeCLIClient.swift" \
  "$project_dir/Tests/SelfTests.swift" \
  -parse-as-library \
  -o "$test_dir/self-tests"

"$test_dir/self-tests"
