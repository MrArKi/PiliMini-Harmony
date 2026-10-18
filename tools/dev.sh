#!/bin/sh
set -eu
# PiliMini 开发辅助脚本（CLI 全流程：构建 / 安装 / 启动 / 交互 / 截图 / 日志）
# 用法:
#   tools/dev.sh build              编译 HAP（debug，双架构，模拟器用）
#   tools/dev.sh release            编译 arm64-only 包（真机侧载，输出 release/PiliMini-arm64-unsigned.hap）
#   tools/dev.sh install            安装到已连接设备
#   tools/dev.sh start              启动 App
#   tools/dev.sh stop               停止 App
#   tools/dev.sh click X Y          点击坐标
#   tools/dev.sh swipe X1 Y1 X2 Y2  滑动
#   tools/dev.sh bdump              输出当前界面 bounds（dumpLayout）
#   tools/dev.sh shot NAME          截图到 .local-evidence/dev/NAME.jpeg（本地）
#   tools/dev.sh log [SEC]          抓 hilog（默认 5 秒）
PILIMINI_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PILIMINI_HDC="${PILIMINI_HDC:-hdc}"
# 多设备时设置PILIMINI_DEVICE；hdc不在PATH时设置PILIMINI_HDC。
hdc_cmd() {
  if [ -n "${PILIMINI_DEVICE:-}" ]; then
    "$PILIMINI_HDC" -t "$PILIMINI_DEVICE" "$@"
  else
    "$PILIMINI_HDC" "$@"
  fi
}
BUNDLE="com.pilimini.app"
ABILITY="EntryAbility"
export MSYS_NO_PATHCONV=1

case "$1" in
  build)
    cd "$PILIMINI_ROOT" && ./hvigorw assembleHap --no-daemon
    ;;
  release)
    cd "$PILIMINI_ROOT" && ./hvigorw assembleHap --no-daemon -p buildMode=release
    mkdir -p "$PILIMINI_ROOT/release"
    cp "$PILIMINI_ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap" "$PILIMINI_ROOT/release/PiliMini-arm64-unsigned.hap"
    ls -la "$PILIMINI_ROOT/release/PiliMini-arm64-unsigned.hap"
    echo "arm64-only 包已输出（需自行签名后侧载真机）"
    ;;
  install)
    cd "$PILIMINI_ROOT/entry/build/default/outputs/default" && hdc_cmd install -r entry-default-unsigned.hap
    ;;
  start)
    hdc_cmd shell aa start -a "$ABILITY" -b "$BUNDLE"
    ;;
  stop)
    hdc_cmd shell aa force-stop "$BUNDLE"
    ;;
  click)
    hdc_cmd shell uitest uiInput click "$2" "$3"
    ;;
  swipe)
    hdc_cmd shell uitest uiInput swipe "$2" "$3" "$4" "$5" "${6:-600}"
    ;;
  bdump)
    hdc_cmd shell uitest dumpLayout -p /data/local/tmp/layout.json
    hdc_cmd shell cat /data/local/tmp/layout.json
    ;;
  shot)
    mkdir -p "$PILIMINI_ROOT/.local-evidence/dev"
    hdc_cmd shell snapshot_display -f /data/local/tmp/"$2".jpeg
    cd "$PILIMINI_ROOT" && hdc_cmd file recv /data/local/tmp/"$2".jpeg ".local-evidence/dev/$2.jpeg"
    ;;
  log)
    mkdir -p "$PILIMINI_ROOT/.local-evidence/dev"
    hdc_cmd hilog -x > "$PILIMINI_ROOT/.local-evidence/dev/hilog.txt" 2>&1 &
    LOGPID=$!
    sleep "${2:-5}"
    kill $LOGPID 2>/dev/null
    tail -60 "$PILIMINI_ROOT/.local-evidence/dev/hilog.txt"
    ;;
  *)
    echo "unknown cmd: $1"
    ;;
esac
