#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_name="Subscription Manager"
executable_name="subscription-manager"
bundle_dir="$project_dir/dist/$app_name.app"
icon_source="$project_dir/Resources/Assets/app-icon.png"
icon_work_dir="$(mktemp -d /tmp/subscription-manager-icon.XXXXXX)"
iconset_dir="$icon_work_dir/AppIcon.iconset"
trap 'rm -rf "$icon_work_dir"' EXIT

cd "$project_dir"
swift build -c release

rm -rf "$bundle_dir"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
cp "$project_dir/.build/release/$executable_name" "$bundle_dir/Contents/MacOS/$executable_name"
cp "$project_dir/Resources/Info.plist" "$bundle_dir/Contents/Info.plist"
cp -R "$project_dir/Resources/Assets" "$bundle_dir/Contents/Resources/Assets"

mkdir -p "$iconset_dir"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$bundle_dir/Contents/Resources/AppIcon.icns"
chmod +x "$bundle_dir/Contents/MacOS/$executable_name"

codesign --force --deep --sign - "$bundle_dir"
echo "$bundle_dir"
