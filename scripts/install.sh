#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_name="Codex Quota"
source_app="$project_dir/dist/$app_name.app"
install_dir="$HOME/Applications"
installed_app="$install_dir/$app_name.app"
installed_executable="$installed_app/Contents/MacOS/CodexQuota"

"$project_dir/scripts/build-app.sh"
mkdir -p "$install_dir"

existing_pid="$(pgrep -f "$installed_executable" | head -1 || true)"
if [[ -n "$existing_pid" ]]; then
  osascript -e 'tell application id "com.viictorjimenezzz.codex-quota" to quit' 2>/dev/null || true
  for _ in {1..20}; do
    kill -0 "$existing_pid" 2>/dev/null || break
    sleep 0.1
  done
  kill "$existing_pid" 2>/dev/null || true
fi

rm -rf "$installed_app"
cp -R "$source_app" "$installed_app"
open "$installed_app"

echo "Installed $app_name in $installed_app"
echo "Existing accounts and logins were preserved."
