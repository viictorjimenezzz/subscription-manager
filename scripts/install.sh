#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_name="Subscription Manager"
source_app="$project_dir/dist/$app_name.app"
install_dir="$HOME/Applications"
installed_app="$install_dir/$app_name.app"
installed_executable="$installed_app/Contents/MacOS/subscription-manager"
cli_dir="$HOME/.local/bin"
cli_link="$cli_dir/subscription-manager"

quit_app() {
  local bundle_id="$1" executable="$2"
  local pid
  pid="$(pgrep -f "$executable" | head -1 || true)"
  [[ -z "$pid" ]] && return 0
  osascript -e "tell application id \"$bundle_id\" to quit" 2>/dev/null || true
  for _ in {1..30}; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill "$pid" 2>/dev/null || true
}

"$project_dir/scripts/build-app.sh"
mkdir -p "$install_dir"

# Retire earlier versions: Codex Quota 1.x and Quota Manager 2.x. Their
# accounts are moved into ~/.subscription-manager on first launch.
legacy_app="$install_dir/Codex Quota.app"
quit_app "com.viictorjimenezzz.codex-quota" "$legacy_app/Contents/MacOS/CodexQuota"
rm -rf "$legacy_app"
previous_app="$install_dir/Quota Manager.app"
quit_app "com.viictorjimenezzz.quota-manager" "$previous_app/Contents/MacOS/quota-manager"
rm -rf "$previous_app"
if [[ -L "$cli_dir/quota-manager" ]]; then rm "$cli_dir/quota-manager"; fi

quit_app "com.viictorjimenezzz.subscription-manager" "$installed_executable"
rm -rf "$installed_app"
cp -R "$source_app" "$installed_app"

mkdir -p "$cli_dir"
ln -sf "$installed_executable" "$cli_link"

open "$installed_app"

echo "Installed $app_name in $installed_app"
echo "Command-line tool linked at $cli_link"
echo "Existing accounts and logins were preserved."
