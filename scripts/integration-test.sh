#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
test_dir="$(mktemp -d /tmp/codex-quota-integration.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT

swiftc \
  "$project_dir/Sources/CodexQuota/JSONValue.swift" \
  "$project_dir/Sources/CodexQuota/QuotaModels.swift" \
  "$project_dir/Sources/CodexQuota/CodexAppServerClient.swift" \
  "$project_dir/Tests/AppServerIntegration.swift" \
  -parse-as-library \
  -o "$test_dir/app-server-integration"

"$test_dir/app-server-integration"
