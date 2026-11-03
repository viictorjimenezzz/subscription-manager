#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
sources="$project_dir/Sources/SubscriptionManager"
test_dir="$(mktemp -d /tmp/subscription-manager-integration.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT

swiftc \
  "$sources/JSONValue.swift" \
  "$sources/QuotaModels.swift" \
  "$sources/ClaudeUsageParser.swift" \
  "$sources/Vault.swift" \
  "$sources/QuotaBackend.swift" \
  "$sources/CodexAppServerClient.swift" \
  "$sources/ClaudeCLIClient.swift" \
  "$project_dir/Tests/ProviderIntegration.swift" \
  -parse-as-library \
  -o "$test_dir/provider-integration"

"$test_dir/provider-integration"
