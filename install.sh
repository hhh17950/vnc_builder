#!/usr/bin/env bash
set -euo pipefail

bundle_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
binary_source="$bundle_dir/dist/vnc_worker"
config_source="$bundle_dir/vnc-worker.env"
service_source="$bundle_dir/vnc-worker.service"
manager_source="$bundle_dir/vnc_manager.sh"
install_dir="${VNC_BUILDER_INSTALL_DIR:-/opt/vnc_worker}"
config_target="${VNC_BUILDER_CONFIG_FILE:-/etc/vnc-worker.env}"
unit_target="${VNC_BUILDER_UNIT_FILE:-/etc/systemd/system/vnc-worker.service}"
service_name="vnc-worker.service"
systemctl_bin="${VNC_BUILDER_SYSTEMCTL:-systemctl}"
journalctl_bin="${VNC_BUILDER_JOURNALCTL:-journalctl}"

usage() {
  cat <<'EOF'
用法: ./install.sh {install|start|stop|restart|status|logs|uninstall} [--purge]

  install    安装或更新二进制与 systemd 服务，并启动 Worker
  start      启动服务
  stop       停止服务
  restart    重启服务（修改 /etc/vnc-worker.env 后使用）
  status     查看服务状态
  logs       实时查看 journal 日志
  uninstall  停止并移除服务与二进制；默认保留配置和日志
  --purge    仅用于 uninstall，同时删除 /etc/vnc-worker.env
EOF
}

require_absolute_path() {
  local value="$1" name="$2"
  if [[ "$value" != /* || "$value" =~ [[:space:]] ]]; then
    echo "$name 必须是没有空白字符的绝对路径: $value" >&2
    exit 2
  fi
}

require_config() {
  local config_file="$1"
  if [[ ! -f "$config_file" ]]; then
    echo "缺少 $config_file；请先复制 vnc-worker.env.example 并填写真实配置。" >&2
    exit 2
  fi
  for key in VNC_API_URL VNC_REDIS_URL VNC_WORKER_ID VNC_SLOT_COUNT VNC_MANAGER_SCRIPT VNC_DESKTOP_USER VNC_LOG_DIR; do
    if ! grep -Eq "^${key}=[^[:space:]]+" "$config_file"; then
      echo "配置缺少 $key: $config_file" >&2
      exit 2
    fi
  done
}

config_value() {
  local key="$1" config_file="$2"
  sed -n "s/^${key}=//p" "$config_file" | tail -n 1
}

install_worker() {
  local manager_script desktop_user log_dir
  [[ -f "$binary_source" ]] || { echo "缺少 $binary_source" >&2; exit 2; }
  [[ -x "$binary_source" ]] || { echo "可执行文件没有执行权限: $binary_source" >&2; exit 2; }
  [[ -f "$service_source" ]] || { echo "缺少 $service_source" >&2; exit 2; }
  [[ -f "$manager_source" ]] || { echo "缺少 $manager_source" >&2; exit 2; }
  if [[ ! -f "$config_target" ]]; then
    require_config "$config_source"
    install -d -m 755 "$(dirname "$config_target")"
    install -m 600 "$config_source" "$config_target"
  else
    require_config "$config_target"
    echo "保留已有配置: $config_target（修改后执行 restart）"
  fi
  desktop_user="$(config_value VNC_DESKTOP_USER "$config_target")"
  [[ "$desktop_user" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || { echo "无效桌面账号" >&2; exit 2; }
  log_dir="$(config_value VNC_LOG_DIR "$config_target")"
  require_absolute_path "$log_dir" "VNC_LOG_DIR"
  # 安装需管理员权限；运行服务始终使用桌面账号。
  mkdir -p "$log_dir/tasks"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    chown "$desktop_user" "$log_dir" "$log_dir/tasks"
    local worker_lock="$log_dir/$(config_value VNC_WORKER_ID "$config_target").lock"
    [[ ! -f "$worker_lock" ]] || chown "$desktop_user" "$worker_lock"
  fi
  manager_script="$(config_value VNC_MANAGER_SCRIPT "$config_target")"
  require_absolute_path "$manager_script" "VNC_MANAGER_SCRIPT"

  # 目录权限由内网运维统一管理；这里只安装脚本文件，不修改目录权限。
  mkdir -p "$(dirname "$manager_script")"
  install -m 755 "$manager_source" "$manager_script"

  install -d -m 755 "$install_dir"
  # 先写临时文件再替换，避免覆盖正在运行的可执行文件。
  install -m 755 "$binary_source" "$install_dir/.vnc_worker.new"
  mv -f "$install_dir/.vnc_worker.new" "$install_dir/vnc_worker"
  install -d -m 755 "$(dirname "$unit_target")"
  sed \
    -e "s|@INSTALL_DIR@|$install_dir|g" \
    -e "s|@CONFIG_FILE@|$config_target|g" \
    -e "s|@DESKTOP_USER@|$desktop_user|g" \
    "$service_source" > "$unit_target"
  chmod 644 "$unit_target"
  "$systemctl_bin" daemon-reload
  "$systemctl_bin" enable "$service_name"
  "$systemctl_bin" restart "$service_name"
  echo "已安装并启动 $service_name；查看状态: $0 status"
}

uninstall_worker() {
  local purge="${1:-}"
  if [[ "$purge" != "" && "$purge" != "--purge" ]]; then
    usage >&2
    exit 2
  fi
  if [[ -f "$unit_target" ]]; then
    "$systemctl_bin" stop "$service_name"
    "$systemctl_bin" disable "$service_name"
    rm -f "$unit_target"
    "$systemctl_bin" daemon-reload
  fi
  rm -f "$install_dir/vnc_worker"
  if [[ "$purge" == "--purge" ]]; then
    rm -f "$config_target"
  fi
  echo "已卸载 $service_name；任务报告和日志未删除。"
}

require_absolute_path "$install_dir" "安装目录"
require_absolute_path "$config_target" "配置文件路径"
require_absolute_path "$unit_target" "服务文件路径"

case "${1:-}" in
  install) [[ "$#" -eq 1 ]] || { usage >&2; exit 2; }; install_worker ;;
  start) [[ "$#" -eq 1 ]] || { usage >&2; exit 2; }; "$systemctl_bin" start "$service_name" ;;
  stop) [[ "$#" -eq 1 ]] || { usage >&2; exit 2; }; "$systemctl_bin" stop "$service_name" ;;
  restart) [[ "$#" -eq 1 ]] || { usage >&2; exit 2; }; "$systemctl_bin" restart "$service_name" ;;
  status) [[ "$#" -eq 1 ]] || { usage >&2; exit 2; }; "$systemctl_bin" status --no-pager "$service_name" ;;
  logs) [[ "$#" -eq 1 ]] || { usage >&2; exit 2; }; "$journalctl_bin" -u "$service_name" -f ;;
  uninstall) [[ "$#" -le 2 ]] || { usage >&2; exit 2; }; uninstall_worker "${2:-}" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
