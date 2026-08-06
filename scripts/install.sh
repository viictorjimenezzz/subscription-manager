#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_name="Codex Quota"
source_app="$project_dir/dist/$app_name.app"
install_dir="$HOME/Applications"
installed_app="$install_dir/$app_name.app"

"$project_dir/scripts/build-app.sh"
mkdir -p "$install_dir"
rm -rf "$installed_app"
cp -R "$source_app" "$installed_app"
open "$installed_app"

echo "Installed $app_name in $installed_app"
