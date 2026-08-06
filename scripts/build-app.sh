#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_name="Codex Quota"
bundle_dir="$project_dir/dist/$app_name.app"

cd "$project_dir"
swift build -c release

rm -rf "$bundle_dir"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
cp "$project_dir/.build/release/CodexQuota" "$bundle_dir/Contents/MacOS/CodexQuota"
cp "$project_dir/Resources/Info.plist" "$bundle_dir/Contents/Info.plist"
chmod +x "$bundle_dir/Contents/MacOS/CodexQuota"

codesign --force --deep --sign - "$bundle_dir"
echo "$bundle_dir"
