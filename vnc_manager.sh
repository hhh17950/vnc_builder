#!/usr/bin/env bash
set -uo pipefail

# TurboVNC 只管理单一 Linux 账号的 :1～:4，不负责安装和修改桌面配置。
readonly VNCSERVER_BIN="${VNCSERVER_BIN:-/opt/TurboVNC/bin/vncserver}"
readonly VNC_DESKTOP_USER="${VNC_DESKTOP_USER:-snskap}"
readonly MAX_DISPLAYS=4

usage() {
  cat <<'EOF'
用法:
  bash /opt/scripts/vnc_manager.sh create [-n 1-4]
  bash /opt/scripts/vnc_manager.sh list
  bash /opt/scripts/vnc_manager.sh stop [:[1-4]]
  bash /opt/scripts/vnc_manager.sh help

示例:
  bash /opt/scripts/vnc_manager.sh create
  bash /opt/scripts/vnc_manager.sh create -n 4
  bash /opt/scripts/vnc_manager.sh stop :2
  bash /opt/scripts/vnc_manager.sh stop
EOF
}

fail() {
  echo "错误: $*" >&2
  exit 2
}

require_vnc_user() {
  getent passwd "$VNC_DESKTOP_USER" >/dev/null 2>&1 \
    || fail "Linux 用户不存在: $VNC_DESKTOP_USER"
}

require_vncserver() {
  [[ -x "$VNCSERVER_BIN" ]] || fail "TurboVNC 程序不存在或不可执行: $VNCSERVER_BIN"
}

lock_mutation() {
  # 锁定脚本自身，无需创建可能产生跨用户权限问题的锁文件。
  exec 9<"${BASH_SOURCE[0]}" || fail "无法打开脚本锁"
  flock -x 9 || fail "无法获取 VNC 管理锁"
}

run_vncserver() {
  local current_user home command argument
  current_user="$(id -un)"
  home="$(getent passwd "$VNC_DESKTOP_USER" | awk -F: '{print $6}')"

  if [[ "$current_user" == "$VNC_DESKTOP_USER" ]]; then
    HOME="$home" USER="$VNC_DESKTOP_USER" LOGNAME="$VNC_DESKTOP_USER" \
      "$VNCSERVER_BIN" "$@"
    return
  fi
  [[ "${EUID:-$(id -u)}" -eq 0 ]] \
    || fail "请使用 $VNC_DESKTOP_USER 或 root 运行脚本"

  printf -v command '%q ' env "HOME=$home" "USER=$VNC_DESKTOP_USER" \
    "LOGNAME=$VNC_DESKTOP_USER" "$VNCSERVER_BIN"
  for argument in "$@"; do
    printf -v argument '%q' "$argument"
    command+="$argument "
  done
  su -s /bin/bash -c "$command" "$VNC_DESKTOP_USER"
}

is_xvnc_running() {
  local display="$1" target_uid
  target_uid="$(id -u "$VNC_DESKTOP_USER")"
  ps -eo uid=,comm=,args= | awk -v uid="$target_uid" -v display="$display" '
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
  local group number state separator=""
  require_vnc_user
  group="$(id -gn "$VNC_DESKTOP_USER")"
  print_inventory

  printf '['
  for number in $(seq 1 "$MAX_DISPLAYS"); do
    state="stopped"
    if is_xvnc_running ":$number"; then
      state="running"
    fi
    printf '%s{"user":"%s","group":"%s","display":":%d","state":"%s"}' \
      "$separator" "$VNC_DESKTOP_USER" "$group" "$number" "$state"
    separator=','
  done
  printf ']\n'
}

create_desktops() {
  local count="$MAX_DISPLAYS" number failed=0
  if [[ "$#" -gt 0 ]]; then
    [[ "$#" -eq 2 && "$1" == "-n" ]] || fail "create 只接受可选参数 -n 1-4"
    count="$2"
  fi
  [[ "$count" =~ ^[1-4]$ ]] || fail "-n 必须是 1 到 4 的整数"
  require_vnc_user
  require_vncserver
  lock_mutation

  for number in $(seq 1 "$count"); do
    if is_xvnc_running ":$number"; then
      echo ":$number 已运行，跳过" >&2
      continue
    fi
    echo ":$number 未运行，开始创建" >&2
    run_vncserver ":$number" \
      -geometry 1920x1080 \
      -depth 24 \
      -localhost no \
      -nevershared \
      -securitytypes none >&2 || failed=1
  done
  list_desktops
  return "$failed"
}

stop_desktops() {
  local displays=(":1" ":2" ":3" ":4") display
  if [[ "$#" -gt 0 ]]; then
    [[ "$#" -eq 1 && "$1" =~ ^:[1-4]$ ]] || fail "display 必须是 :1、:2、:3 或 :4"
    displays=("$1")
  fi
  require_vnc_user
  require_vncserver
  lock_mutation

  for display in "${displays[@]}"; do
    run_vncserver -kill "$display" >&2 || true
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
