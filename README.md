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

每台物理机把 `VNC_WORKER_ID` 配置为自己的固定管理网 IP。确认以下两项已经存在：

```text
VNC_MANAGER_SCRIPT=/opt/vnc_manager/vnc_manager.sh
VNC_SHARED_ROOT=/mnt/shared-tests
```

Worker 启动时会自动执行 `vnc_manager.sh create -n VNC_SLOT_COUNT`，无需提前手工创建桌面。

## 3. 安装

把整个 `vnc_builder` 目录复制到物理机，然后执行：

```bash
sudo bash install.sh install
```

程序安装到 `/opt/vnc_worker/vnc_worker`，配置安装到 `/etc/vnc-worker.env`，服务名称为 `vnc-worker.service`。重复执行 install 会更新程序并保留现有配置。

## 4. 日常操作

```bash
sudo bash install.sh start
sudo bash install.sh stop
sudo bash install.sh restart
sudo bash install.sh status
sudo bash install.sh logs
```

修改 `/etc/vnc-worker.env` 后执行 restart。注册冲突时，先确认旧 Worker 已退出，再调用调度服务：

```bash
curl -X POST http://vnc-schedule:8088/api/v1/workers/192.168.10.21/unregister
sudo bash install.sh restart
```

## 5. 卸载

```bash
sudo bash install.sh uninstall
```

默认保留 `/etc/vnc-worker.env`、日志和任务报告。连配置一起删除：

```bash
sudo bash install.sh uninstall --purge
```

## 物理机准备

- Worker 服务以 root 运行；任务单元通过 systemd `User=` 切换到 VNC 用户。
- `vnc_manager.sh` 使用 `root:root 0755`，`/etc/vnc_manage` 使用 `0755`，配置使用 `0644`，不要设置 777。
- `/etc/vnc-worker.env` 使用 `root:root 0600`。
- TurboVNC `xstartup` 和桌面 dconf 负责关闭锁屏、黑屏和休眠；Worker 只用 `xset q` 检查 DISPLAY。
- Squish Server 端口由任务脚本管理，同一物理机上的并发任务必须避免端口冲突。

安装脚本测试：

```bash
python3 -m pytest -q tests
```
