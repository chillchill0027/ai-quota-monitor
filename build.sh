#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")" && pwd)"
cd "$project_root"

output_dir="${BUILD_OUTPUT_DIR:-$project_root}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
build_dir="$(mktemp -d "$output_dir/.quota-build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

info_template="$project_root/packaging/Info.plist"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_template")"
deployment_target="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_template")"
signing_identity="${CODE_SIGN_IDENTITY:--}"

bash scripts/build-app-icon.sh
echo "正在编译 AI额度看板 $app_version (arm64 / macOS $deployment_target+) ..."
swiftc -O -target "arm64-apple-macosx$deployment_target" -sdk "$(xcrun --show-sdk-path)" \
    -module-cache-path /tmp/swift-module-cache Sources/*.swift -o "$build_dir/AIQuotaMonitor"

# Build complete bundles from the source template; a fresh checkout needs no existing .app.
for app_name in "AIQuotaMonitor.app" "AI额度看板.app"; do
    staged_app="$build_dir/$app_name"
    mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
    cp "$info_template" "$staged_app/Contents/Info.plist"
    cp "$build_dir/AIQuotaMonitor" "$staged_app/Contents/MacOS/AIQuotaMonitor"
    cp -R Resources/ProviderIcons "$staged_app/Contents/Resources/"
    cp Resources/ThirdPartyNotices.txt Resources/AppIcon.icns "$staged_app/Contents/Resources/"
    xattr -cr "$staged_app"
    if [ "$signing_identity" = "-" ]; then
        codesign --force --sign - "$staged_app"
    else
        codesign --force --options runtime --timestamp --sign "$signing_identity" "$staged_app"
    fi
    codesign --verify --deep --strict "$staged_app"

    destination="$output_dir/$app_name"
    previous="$build_dir/previous-$app_name"
    if [ -e "$destination" ]; then mv "$destination" "$previous"; fi
    if ! mv "$staged_app" "$destination"; then
        if [ -e "$previous" ]; then mv "$previous" "$destination"; fi
        exit 1
    fi
    touch "$destination"
done
echo "✅ 两个 App 入口均已生成并签名：$output_dir"
