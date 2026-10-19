#!/usr/bin/env bash
set -uo pipefail

# TurboVNC 单账号多桌面管理：只负责当前账号 :1～:4 的创建、查询、停止。
# 不涉及账号切换、调度授权、锁屏策略、VirtualGL 或 Squish。
#
# 不继承调用者的 XAUTHORITY：vncserver 会直接把该变量当作 VNC 的认证文件
# （vncserver 内 $xauthorityFile = $ENV{XAUTHORITY}）。从 GDM 桌面终端运行时，
# 它指向 /run/gdm/auth-for-<user>-*/database，该文件由 GDM 管理且会轮换，
# xauth 写入时可能长时间等锁，导致 create 看起来卡住。unset 后 vncserver
# 会回退到 ~/.Xauthority。
unset XAUTHORITY
readonly VNCSERVER_BIN="${VNCSERVER_BIN:-/opt/TurboVNC/bin/vncserver}"
readonly MAX_DISPLAYS=4
readonly VNC_USER="$(id -un)"
readonly VNC_UID="$(id -u)"
readonly VNC_GROUP="$(id -gn)"

usage() {
  cat <<'EOF'
用法:
  bash vnc_manager.sh create [-n 1-4]
  bash vnc_manager.sh list
  bash vnc_manager.sh stop [:[1-4]]
  bash vnc_manager.sh help

示例:
  bash vnc_manager.sh create
  bash vnc_manager.sh create -n 4
  bash vnc_manager.sh stop :2
  bash vnc_manager.sh stop
EOF
}

fail() {
  echo "错误: $*" >&2
  exit 2
}

require_vncserver() {
  [[ -x "$VNCSERVER_BIN" ]] || fail "TurboVNC 程序不存在或不可执行: $VNCSERVER_BIN"
}

is_xvnc_running() {
  local display="$1"
  ps -eo uid=,comm=,args= | awk -v uid="$VNC_UID" -v display="$display" '
    $1 == uid && $2 == "Xvnc" {
      for (i = 3; i <= NF; i++) {
        if ($i == display) {
          found = 1
          exit
        }
      }
    }
    END { exit(found ? 0 : 1) }
  '
}

print_inventory() {
  {
    echo "===== X11 sockets: /tmp/.X11-unix ====="
    if [[ -d /tmp/.X11-unix ]]; then
      find /tmp/.X11-unix -maxdepth 1 -type s -name 'X*' -print 2>/dev/null | sort
    else
      echo "(目录不存在)"
    fi
    echo "===== TurboVNC Xvnc processes ====="
    ps -eo user=,pid=,comm=,args= | awk '$3 == "Xvnc"' || true
    echo "===== Xorg processes (read-only) ====="
    ps -eo user=,pid=,comm=,args= | awk '$3 == "Xorg"' || true
    echo "===== Worker JSON (stdout) ====="
  } >&2
}

list_desktops() {
  local number state separator=""
  print_inventory

  printf '['
  for number in $(seq 1 "$MAX_DISPLAYS"); do
    state="stopped"
    if is_xvnc_running ":$number"; then
      state="running"
    fi
    printf '%s{"user":"%s","group":"%s","display":":%d","state":"%s"}' \
      "$separator" "$VNC_USER" "$VNC_GROUP" "$number" "$state"
    separator=','
  done
  printf ']\n'
}

create_desktops() {
  local count="$MAX_DISPLAYS" number
  if [[ "$#" -gt 0 ]]; then
    [[ "$#" -eq 2 && "$1" == "-n" ]] || fail "create 只接受可选参数 -n 1-4"
    count="$2"
  fi
  [[ "$count" =~ ^[1-4]$ ]] || fail "-n 必须是 1 到 4 的整数"
  require_vncserver

  for number in $(seq 1 "$count"); do
    if is_xvnc_running ":$number"; then
      echo ":$number 已运行，跳过" >&2
      continue
    fi
    echo ":$number 未运行，开始创建" >&2
    if ! "$VNCSERVER_BIN" ":$number" \
        -geometry 1920x1080 \
        -depth 24 \
        -nevershared \
        -securitytypes none >&2; then
      echo ":$number 创建失败" >&2
      list_desktops
      return 1
    fi
  done
  list_desktops
}

stop_desktops() {
  local displays=(":1" ":2" ":3" ":4") display
  if [[ "$#" -gt 0 ]]; then
    [[ "$#" -eq 1 && "$1" =~ ^:[1-4]$ ]] || fail "display 必须是 :1、:2、:3 或 :4"
    displays=("$1")
  fi
  require_vncserver

  for display in "${displays[@]}"; do
    "$VNCSERVER_BIN" -kill "$display" >&2 || true
  done
  list_desktops
}

case "${1:-help}" in
  create)
    shift
    create_desktops "$@"
    ;;
  list)
    shift
    [[ "$#" -eq 0 ]] || fail "list 不接受参数"
    list_desktops
    ;;
  stop)
    shift
    stop_desktops "$@"
    ;;
  help|-h|--help)
    [[ "$#" -le 1 ]] || fail "help 不接受参数"
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
