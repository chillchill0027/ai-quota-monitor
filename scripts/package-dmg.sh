#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

app_path=""
output_dir="$project_root/dist"
usage() {
    echo "用法：$0 [--app /path/to/AI额度看板.app] [--output-dir /path/to/dist]"
    echo "未指定 --app 时，在临时目录从源码构建，不覆盖根目录正在使用的 App。"
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --app)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            app_path="$2"; shift 2 ;;
        --output-dir)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            output_dir="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
work_dir="$(mktemp -d "$output_dir/.quota-dmg.XXXXXX")"
mount_point=""
cleanup() {
    if [ -n "$mount_point" ]; then hdiutil detach "$mount_point" >/dev/null || true; fi
    rm -rf "$work_dir"
}
trap cleanup EXIT

if [ -z "$app_path" ]; then
    BUILD_OUTPUT_DIR="$work_dir/build" bash "$project_root/build.sh"
    app_path="$work_dir/build/AI额度看板.app"
else
    app_path="$(cd "$(dirname "$app_path")" && pwd)/$(basename "$app_path")"
fi

info_path="$app_path/Contents/Info.plist"
[ -f "$info_path" ] || { echo "找不到应用 Info.plist：$app_path" >&2; exit 1; }
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_path")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_path")"
[ "$bundle_id" = "com.chill.AIQuotaMonitor" ] || { echo "拒绝打包不匹配的应用标识。" >&2; exit 1; }
architecture="$(lipo -archs "$app_path/Contents/MacOS/AIQuotaMonitor")"
[ "$architecture" = "arm64" ] || { echo "此打包脚本仅支持已验证的 arm64 构建。" >&2; exit 1; }
codesign --verify --deep --strict "$app_path"

dmg_name="AIQuotaMonitor-$app_version-arm64.dmg"
dmg_path="$output_dir/$dmg_name"
checksum_path="$dmg_path.sha256"
# Only replace a previous artifact whose companion checksum still validates it.
# A same-named user file or incomplete publication is left untouched.
if [ -e "$dmg_path" ] || [ -e "$checksum_path" ]; then
    [ -f "$dmg_path" ] && [ -f "$checksum_path" ] || {
        echo "输出已存在且缺少配套校验文件，请使用新的 --output-dir：$dmg_path" >&2; exit 1;
    }
    (cd "$output_dir" && shasum -a 256 -c "$(basename "$checksum_path")" >/dev/null) || {
        echo "已有 DMG 校验不匹配，未覆盖：$dmg_path" >&2; exit 1;
    }
fi

image_root="$work_dir/image"
mkdir -p "$image_root"
ditto "$app_path" "$image_root/AI额度看板.app"
ln -s /Applications "$image_root/Applications"
cat > "$image_root/安装说明.txt" <<'NOTES'
AI 额度看板

将「AI额度看板.app」拖入「Applications」，再从应用程序中打开。
支持 Apple 芯片 Mac，macOS 14 或更新版本。
原生 Liquid Glass 外观需要 macOS 26 或更新版本。

本下载包使用本地临时签名（ad-hoc），尚未取得 Developer ID 签名或 Apple 公证。
macOS 可能在首次打开时显示安全提示，请确认下载来源并按系统提供的说明处理。

首次使用需配置自己的 DeepSeek Key，或登录相应供应商账户。
OpenAI 卡片依赖已登录的 Codex CLI，Antigravity 卡片依赖本机运行的对应服务。
本安装包不包含开发者的 API Key、登录会话或个人额度缓存。
NOTES

temporary_dmg="$work_dir/$dmg_name"
hdiutil create -volname "AI额度看板" -srcfolder "$image_root" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 "$temporary_dmg"
hdiutil verify "$temporary_dmg"
hdiutil attach -readonly -nobrowse -plist "$temporary_dmg" > "$work_dir/attach.plist"
mount_point="$(python3 - "$work_dir/attach.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    record = plistlib.load(stream)
points = [entity['mount-point'] for entity in record.get('system-entities', []) if 'mount-point' in entity]
if len(points) != 1:
    raise SystemExit('Expected one DMG mount point')
print(points[0])
PY
)"
python3 - "$mount_point" <<'PY'
from pathlib import Path
import plistlib, sys
root = Path(sys.argv[1])
payload = {p.name for p in root.iterdir() if not p.name.startswith('.')}
assert payload == {'AI额度看板.app', 'Applications', '安装说明.txt'}, payload
assert (root / 'Applications').is_symlink()
assert (root / 'Applications').readlink() == Path('/Applications')
with (root / 'AI额度看板.app/Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleIdentifier'] == 'com.chill.AIQuotaMonitor'
assert info['CFBundleIconFile'] == 'AppIcon.icns'
print('DMG 内容与 Applications 链接验证通过。')
PY
codesign --verify --deep --strict "$mount_point/AI额度看板.app"
hdiutil detach "$mount_point"
mount_point=""

checksum="$(shasum -a 256 "$temporary_dmg")"
checksum="${checksum%% *}"
printf '%s  %s\n' "$checksum" "$dmg_name" > "$work_dir/checksum.sha256"
mv -f "$temporary_dmg" "$dmg_path"
mv -f "$work_dir/checksum.sha256" "$checksum_path"
echo "✅ DMG 已生成并验证：$dmg_path"
echo "SHA256：$checksum"
