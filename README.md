# vnc_build

Worker 的 Linux 安装包与系统文档仓库，原本地目录名为 `vnc_builder`。仓库不包含 ISO、RPM、虚拟机磁盘、许可证或已构建二进制。

## 基础结构

```text
install.sh                 安装、更新与管理 systemd 服务
vnc-worker.service         服务模板，以桌面账号运行
vnc-worker.env.example     部署配置示例
vnc_manager.sh             当前账号 :1～:4 的 TurboVNC 管理
xstartup.example           GNOME 启动模板
dist/.gitkeep             Linux Worker 二进制放置位置
tests/                    安装器与 VNC 脚本测试
 docs/                     需求、架构、部署、Windows 准备及验收
```

## 安装与启动

先在兼容 CentOS 7 的 Linux 构建环境生成 `vnc_worker/dist/vnc_worker`，然后：

```bash
# 三个仓库按同级目录检出；在 vnc_build 根目录执行。
cp ../vnc_worker/dist/vnc_worker dist/vnc_worker
cp vnc-worker.env.example vnc-worker.env
# 编辑服务地址、唯一 Worker ID、桌面账号和日志目录。
sudo bash install.sh install
sudo bash install.sh status
sudo bash install.sh logs
```

日常操作：`sudo bash install.sh start|stop|restart|status|logs|uninstall`。
重复安装保留已有配置；修改桌面账号后须重新 install。安装器不安装 TurboVNC/VirtualGL、不创建账号，也不覆盖用户的 `~/.vnc/xstartup`。

测试：`../vnc_worker/.venv/bin/python -m pytest -q tests`（或其他已安装 pytest 的 Python 环境）。

## 文档入口

| 文档 | 内容 |
| --- | --- |
| [requirements.md](docs/requirements.md) | 从现有材料整理的原始需求基线与后续确认 |
| [architecture.md](docs/architecture.md) | 当前组件、执行链路、状态机与实现边界 |
| [deployment.md](docs/deployment.md) | API、Worker、systemd、配置与运维 |
| [windows-vm.md](docs/windows-vm.md) | Windows + VMware + CentOS 7 + VirtualGL/TurboVNC 准备和实施步骤 |
| [gnome-desktop.md](docs/gnome-desktop.md) | GNOME 模板替换、防锁屏与回退 |
| [acceptance.md](docs/acceptance.md) | 真机/虚拟机验收与记录模板 |
| [development-guidelines.md](docs/development-guidelines.md) | 原 AGENT.md 开发约定 |
| [archive/](docs/archive/) | 上版交接文档及已实施计划，保留历史，不作为现行部署指南 |
