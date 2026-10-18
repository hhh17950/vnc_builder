# CentOS 7 验收清单

## 安装前

1. 确认 PyInstaller 程序在兼容 CentOS 7、相同 CPU 架构的环境构建。
2. 确认 `vnc_manager.sh create -n N`、`list`、`stop :N` 和无参数 `stop` 可用。
3. 重复执行 `create -n 4`，确认已运行 DISPLAY 被跳过；手工停止一个空闲 DISPLAY，确认 Worker 定时恢复后重新变为 `idle`。
4. 确认任务 cwd 是实际存在的绝对路径，VNC 用户能访问该目录及 VNC_LOG_DIR 的父目录，任务结果目录由当前账号的 Worker 创建。
5. 使用 `vnc_builder/install.sh install` 安装 Worker。

## VNC 与防锁屏

1. 在 TurboVNC `xstartup` 中执行 `xset s off`、`xset s noblank` 和 `xset -dpms`。
2. 通过桌面 dconf 关闭锁屏和空闲超时，并关闭主机 suspend/hibernate。
3. 在同一桌面账号终端运行 `DISPLAY=:1 xset q`，确认默认 `~/.Xauthority` 可用。
4. 断开 VNC 客户端超过原锁屏时间后重新连接，确认桌面仍可操作。

## 任务与清理

1. 在两个 Slot 同时运行 `xeyes`，确认窗口分别出现在正确 DISPLAY。
2. 取消和超时后确认窗口消失，任务进程组没有残留运行进程。
3. 使用派生子进程并忽略 SIGTERM 的脚本，确认 Squish Server、Runner、AUT 和派生进程最终全部退出；核对实际启动方式没有 daemonize/setsid，若脱离进程组则需在任务脚本显式停止。
4. 确认同一物理机上的任务脚本使用不同 Squish 端口。

## 故障恢复

1. 正常 `systemctl stop vnc-worker` 后确认 API 显示 Worker 离线。
2. 强制结束 Worker 后确认运行中任务在 `deadline + 60s` 后变为 `timed_out` 且不会自动重跑。源码调试遭 SIGKILL 时需手动清理旧进程；服务模式检查 systemd 的 KillMode 兜底清理。
3. 如旧租约阻止注册，确认旧进程已退出后调用 `/api/v1/workers/{worker_id}/unregister`，再重启服务。
4. 传入不存在或无权限的 cwd 时任务应失败并记录原因；普通用户可直接运行和调试，管理命令不得等待交互密码。
5. 检查服务日志和任务 stdout/stderr 分离；运行后台进程后主脚本退出，确认残留由进程组清理。

这些项目只能在真实 CentOS 7、TurboVNC 3.0.1 和 Squish 环境确认；macOS 单元测试不能替代本清单。

## 当前改造补充验收

1. 单个任务重复 claim：相同 Worker/session/slot 返回原授权，其他执行者不能启动。
2. 任务终态重复回报：保持第一次终态；取消与完成、超时与完成竞争符合 API 状态约束。
3. Worker 租约过期：API 不立即修改任务，deadline + 60 秒兜底；新 session 接管旧执行标 unknown。
4. 配置文件服务与可被 API 读取的共享日志路径，确认 job_info 四个字段及上传成功/失败行为；失败不改变终态且不补传。
5. 两个 Slot 同秒使用相同 cwd 时检查日志是否冲突；当前命名只有秒级时间，应作为已知限制记录。
6. 记录部分 DISPLAY 创建失败时启动行为、任务结束时桌面不健康的隔离行为，参见 architecture.md 的已知限制。

## 验收记录模板

| 项目 | 实际版本/配置 | 命令及证据位置 | 结果 |
| --- | --- | --- | --- |
| 宿主机/虚拟机 | 待填 | 待填 | 待验收 |
| GNOME/TurboVNC/VirtualGL | 待填 | 待填 | 待验收 |
| OpenGL renderer | 待填 | glxinfo/vglrun 输出 | 待验收 |
| 并发/取消/超时/恢复 | 待填 | API 与进程检查结果 | 待验收 |
| Squish/AUT | 待填 | 真实业务用例 | 待验收 |

本文件是执行清单，不表示上述项目已经通过。
