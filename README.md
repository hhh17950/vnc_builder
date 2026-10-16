# VNC Worker 安装包

本目录用于把 PyInstaller 生成的 `vnc_worker` 安装为 CentOS 7 systemd 服务。

## 1. 构建程序

必须在与生产机同 CPU 架构、兼容 CentOS 7 glibc 的 Linux 环境构建：

```bash
cd vnc_worker
scripts/build_executable.sh
cp dist/vnc_worker ../vnc_builder/dist/vnc_worker
```

macOS 构建的程序不能复制到 CentOS 7 运行。

## 2. 填写配置

```bash
cd ../vnc_builder
cp vnc-worker.env.example vnc-worker.env
vi vnc-worker.env
```

每台物理机把 `VNC_WORKER_ID` 配置为自己的固定管理网 IP。按实际环境填写桌面账号和日志目录：

```text
VNC_MANAGER_SCRIPT=/opt/scripts/vnc_manager.sh
VNC_DESKTOP_USER=snskap
VNC_LOG_DIR=/var/log/vnc-worker
```

安装包包含生产版 `vnc_manager.sh`，安装时复制到上述路径。Worker 启动时会自动执行 `create -n VNC_SLOT_COUNT`，无需提前手工创建桌面。脚本只管理该账号的 `:1`～`:4`，不管理 Xorg `:0`、VirtualGL、Squish 或桌面静态配置。

`create` 是幂等操作：先按目标用户和 DISPLAY 检查 Xvnc，只创建缺失桌面。Worker 每隔 `VNC_RECOVERY_INTERVAL_SECONDS` 检查空闲桌面并按需恢复；正常领取任务时不会执行创建操作。

## 3. 安装

把整个 `vnc_builder` 目录复制到物理机，然后执行：

```bash
sudo bash install.sh install
```

程序安装到 `/opt/vnc_worker/vnc_worker`，VNC 脚本安装到 `/opt/scripts/vnc_manager.sh`，配置安装到 `/etc/vnc-worker.env`，服务名称为 `vnc-worker.service`。重复执行 install 会更新程序和 VNC 脚本，并保留现有配置。

也可以独立检查 VNC 桌面：

```bash
bash /opt/scripts/vnc_manager.sh create
bash /opt/scripts/vnc_manager.sh list
bash /opt/scripts/vnc_manager.sh stop :2
bash /opt/scripts/vnc_manager.sh stop
```

`list` 在终端展示 X11 套接字、Xvnc 和 Xorg 清单，stdout 只输出 Worker 可解析的 JSON。

## 4. 日常操作

```bash
sudo bash install.sh start
sudo bash install.sh stop
sudo bash install.sh restart
sudo bash install.sh status
sudo bash install.sh logs
```

修改 `/etc/vnc-worker.env` 后执行 restart；修改 `VNC_DESKTOP_USER` 后重新执行 install，以同步 service 的 User 配置。注册冲突时，先确认旧 Worker 已退出，再调用调度服务：

```bash
curl -X POST http://vnc-schedule:8088/api/v1/workers/192.168.10.21/unregister
sudo bash install.sh restart
```

## 5. 卸载

```bash
sudo bash install.sh uninstall
```

默认保留 `/etc/vnc-worker.env`、`/opt/scripts/vnc_manager.sh`、日志和任务报告。连 Worker 配置一起删除：

```bash
sudo bash install.sh uninstall --purge
```

## 物理机准备

- 服务 `KillMode=control-group` 会在停止服务时清理其所有子进程；若 VNC 也是该服务启动且仍在同一 cgroup 内，桌面会一起停止，下次启动时自动补齐。
- 安装服务需要 sudo；安装后 Worker 使用 `VNC_DESKTOP_USER` 账号运行。Worker、VNC 和任务使用同一账号，运行中不调用 su 或 systemd-run。
- 创建任务时传物理机上的绝对 `cwd`，不需要 `VNC_SHARED_ROOT`。桌面账号需能访问该目录及日志目录的父目录。安装器为该账号准备日志目录。
- 服务日志位于 `VNC_LOG_DIR`，任务 stdout/stderr 位于其 `tasks/<任务ID>/<执行ID>/` 下，文件名带日期和分片号。
- `/opt/scripts` 的目录权限由内网运维配置；安装器只把 `vnc_manager.sh` 文件设置为 `0755`。
- `snskap` 的 `~/.vnc/xstartup` 必须预先配置。GNOME 环境使用包内 `xstartup.example`，按照 [GNOME 部署说明](GNOME部署说明.md) 手动替换并验证；脚本不会创建账号或修改该目录。
- `/etc/vnc-worker.env` 使用 `root:root 0600`。
- TurboVNC `xstartup` 和桌面 dconf 负责关闭锁屏、黑屏和休眠；Worker 只用 `xset q` 检查 DISPLAY。
- Squish Server 端口由任务脚本管理，同一物理机上的并发任务必须避免端口冲突。

安装脚本测试：

```bash
python3 -m pytest -q tests
```

## 普通用户直接调试

无需安装服务：以 VNC 桌面账号登录，把配置复制为运行目录下的 `.env`，填写当前账号，并将 `VNC_LOG_DIR` 改为 `./logs`，然后执行 `./dist/vnc_worker run`。不要同时启动安装服务和调试进程。

任务使用独立进程组，任务脚本及 Squish/AUT 不应自行 daemonize/setsid 脱离；需要后台服务时由脚本显式管理停止。取消后检查 stdout、stderr 和进程清理结果。强制 kill 调试 Worker 后须人工确认旧任务已停止。
