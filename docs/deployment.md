# 部署与运行维护

更新：2026-10-18。仓库同级目录为 vnc_schdule_api、vnc_worker、vnc_builder。软件安装与真实桌面验收尚未在本次文档整理中执行。

## 1. 准备与启动顺序

PostgreSQL/Redis → API 迁移与启动 → 桌面环境 → Worker → 提交任务。生产 Worker 使用 CentOS 7、TurboVNC 3.0.1、GNOME；VirtualGL 版本需与内网核对。CPU 架构、glibc、系统账号及 Squish 安装路径必须匹配。

Worker、VNC 和任务使用同一普通账号；安装服务需要管理员权限。所有消费同一队列的机器均须具备任务要求的绝对 cwd、输入文件与程序。需要日志上传时还须建立 API 可访问的日志共享存储。

## 2. API

使用受维护的宿主机或容器部署 PostgreSQL/Redis/API，无需强行安装在 CentOS 7 上。在 API 仓库根目录：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
cp .env.example .env
# 编辑真实配置后：
.venv/bin/alembic upgrade head
.venv/bin/uvicorn src.main:app --host 0.0.0.0 --port 8088
```

升级前停止旧版 Worker，备份数据库并评估迁移。0006 删除 task_attempts、input_path 等字段，将升级时未完成的旧执行归 unknown；downgrade 不能恢复被删除的数据。旧相对 cwd 的 queued 任务应取消并用绝对路径重建。

| API 配置 | 含义 |
| --- | --- |
| VNC_DATABASE_URL | 必填，PostgreSQL asyncpg 连接串；密码由环境提供 |
| VNC_REDIS_URL / VNC_REDIS_PREFIX | 队列连接与命名空间，和 Worker 一致 |
| VNC_TASK_TIMEOUT_SECONDS | 默认 7200，从授权开始 |
| VNC_LEASE_SECONDS | 默认 30 |
| VNC_FILE_MGMT_URL | 可选；空则不上传；占位接口 POST multipart file → id |
| VNC_LOG_DIR / VNC_LOG_TIMEZONE | 默认 logs / Asia/Shanghai |

Compose 的数据库、Redis 和 API 端口只绑定 127.0.0.1。若 Worker 在其他主机/虚拟机上，必须配置受控的可达地址；不要把 Redis 或无鉴权 API 直接暴露到公网。Compose 默认没有传入 VNC_FILE_MGMT_URL，也没有挂载任务日志，上传时需自行补充。

## 3. 图形环境

先按 windows-vm.md 或内网安装规范配置 GNOME、TurboVNC、VirtualGL，再按 gnome-desktop.md 备份并替换 xstartup。安装器不会执行这些步骤。

以桌面账号验证：

```bash
bash /path/to/vnc_builder/vnc_manager.sh create -n 2
bash /path/to/vnc_builder/vnc_manager.sh list
DISPLAY=:1 xset q
DISPLAY=:2 xset q
```

生产脚本 stdout 是 user/group/display/state 的 JSON；诊断清单输出 stderr。脚本默认 VNC 允许网络连接且 securitytypes none，只能用于受信任隔离网络；Windows 验证优先用 Host-only 网络，NAT 联网阶段配置访问限制，不能使用公网端口映射。

## 4. 构建并安装 Worker

源码 Python 需要 3.10+；CentOS 7 自带 Python 不符合要求。选用组织批准的兼容运行时/构建机，不替换系统 Python，也不要把另一个系统构建的二进制当作兼容性证明。

```bash
cd vnc_worker
python3.10 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt -r requirements-build.txt
scripts/build_executable.sh
cp dist/vnc_worker ../vnc_builder/dist/vnc_worker
cd ../vnc_builder
cp vnc-worker.env.example vnc-worker.env
# 编辑配置后：
sudo bash install.sh install
sudo bash install.sh status
```

| Worker 配置 | 含义 |
| --- | --- |
| VNC_API_URL | Worker 可达的 API 地址 |
| VNC_REDIS_URL / VNC_REDIS_PREFIX | 与 API 对齐 |
| VNC_WORKER_ID | 每台机器唯一、稳定；建议填管理网 IP |
| VNC_SLOT_COUNT | 1～4，代码默认 2 |
| VNC_MANAGER_SCRIPT | 通常 /opt/scripts/vnc_manager.sh |
| VNC_DESKTOP_USER | 仅安装器使用，生成 systemd User= |
| VNC_LOG_DIR | 桌面账号可写，常用 /var/log/vnc-worker |
| VNC_HEARTBEAT_SECONDS | 默认 5 |
| VNC_RECOVERY_INTERVAL_SECONDS | 默认 10 |
| VNC_STOP_GRACE_SECONDS / VNC_CLEANUP_SECONDS | 默认 5 / 10 |

安装位置：/opt/vnc_worker/vnc_worker、/opt/scripts/vnc_manager.sh、/etc/vnc-worker.env、/etc/systemd/system/vnc-worker.service。配置权限 0600；安装器保留已有配置。服务以桌面账号运行，WorkingDirectory 为 /opt/vnc_worker。修改账号后重新 install；其他环境变量修改后 restart。

源码调试在 vnc_worker 根目录运行 `.venv/bin/python -m src.cli run`，将 VNC_LOG_DIR 改为可写目录；.env 从当前工作目录读取。不要与服务使用相同 Worker ID 同时运行。

## 5. 联调

```bash
curl http://API_HOST:8088/health
curl http://API_HOST:8088/api/v1/workers
curl -X POST http://API_HOST:8088/api/v1/tasks \
  -H 'Content-Type: application/json' \
  -d '{"command":["/bin/sleep","60"],"cwd":"/tmp","timeout_seconds":120}'
curl http://API_HOST:8088/api/v1/tasks/TASK_ID
curl -X POST http://API_HOST:8088/api/v1/tasks/TASK_ID/cancel
```

取消返回 202 不代表已经清理完成。等待最终 cancelled，并在对应 DISPLAY 和进程组验证。stdout/stderr 文件路径与上传 ID 在查询结果 job_info 中。未配置文件服务时 ID 为空属于预期。

## 6. 运维与回退

- 查看日志：`sudo bash install.sh logs` 或 `sudo journalctl -u vnc-worker -f`。
- 停止/重启：`sudo bash install.sh stop` / `restart`；systemd cgroup 可能同时清理该服务启动的 VNC，下次启动补齐。
- 注册冲突：先确认旧 Worker 及任务进程停止，再 POST /api/v1/workers/WORKER_ID/unregister；旧未完成任务变 unknown，不自动重跑。
- SIGKILL 无 Python 清理保证，源码调试需人工检查残留。
- 服务日志按日/100 MB 分片，压缩保留 30 天；任务输出和 Redis Stream 未自动清理，需规划保留策略。
- 卸载：`sudo bash install.sh uninstall` 保留配置、脚本、日志；仅明确要删除配置时使用 --purge。
- 回退前停止 Worker、保存当前配置与二进制；数据库迁移备份与恢复须单独安排，不能依赖降级命令恢复丢弃字段。

验收证据按 acceptance.md 记录。已知源码边界见 architecture.md。
