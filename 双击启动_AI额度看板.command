#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/AI额度看板.app"
if [ ! -x "$APP/Contents/MacOS/AIQuotaMonitor" ]; then
    "$DIR/build.sh"
fi
open "$APP"
echo "已打开 AI额度看板；点开状态栏或点击查询时按需同步，保留访问冷却。"
