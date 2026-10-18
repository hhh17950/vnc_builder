# Windows 虚拟机准备与实施清单

整理日期：2026-10-18。目标是在 Windows 主机上用 VMware 运行 CentOS 7，复现 GNOME + TurboVNC 3.0.1 + VirtualGL，并验证本项目。本文是执行计划，不代表环境已经搭建或通过验收。

## 1. 开始前需要的信息

- Windows 版本、CPU 型号和架构、内存、剩余磁盘、GPU 型号与驱动版本；确认 BIOS/UEFI 硬件虚拟化已启用。
- 检查 Hyper-V/VBS/WSL 等现有环境，按选定 VMware 版本的要求评估兼容性，不先盲目关闭系统安全功能。
- VMware 的官方安装包及可下载账号；需要账号验证、安装提权或重启时由用户配合。
- 内网实际 VirtualGL、GNOME、Squish 和 AUT 版本；Squish/应用安装包、许可证、最小测试脚本、依赖文件和端口约定。
- 确认 Windows 上 Codex 可执行 PowerShell、联网和访问项目目录；来宾机部署后通过 SSH 操作，不预设具备任意 Windows 图形界面控制能力。

## 2. 资源与目录建议

以下是单机联调的起始配置，不是生产容量保证：建议 Windows 主机至少 16 GB 内存并预留 100 GB 磁盘；先分配虚拟机 4 vCPU、8 GB 内存、80 GB 动态磁盘，验证四桌面时按实际负载调整并为宿主机保留资源。

```text
D:\vnc-lab\
  downloads\       官方安装包、ISO、RPM 和校验文件（不入 Git）
  vm\              虚拟机配置与磁盘（不入 Git）
  source\          三个仓库的同级检出目录
  evidence\        命令输出、截图和验收记录（清理凭据后按需归档）
```

先用 Host-only 网络验证宿主机到虚拟机的 SSH/VNC。安装依赖需要外网时使用受控 NAT；记录所有网卡 IP，不启用公网端口映射。当前 vnc_manager.sh 的 VNC 无认证配置要求隔离网络，不能直接桥接到不可信网络。

## 3. 获取官方材料

| 材料 | 入口与要求 |
| --- | --- |
| VMware Workstation | [官方获取流程](https://knowledge.broadcom.com/external/article/368734/support.broadcom.com)，需要 Broadcom 账号且可能有审核；以账号实际可下载版本为准 |
| CentOS 7.9 x86_64 DVD | [CentOS Vault](https://vault.centos.org/7.9.2009/isos/x86_64/)，选择 CentOS-7-x86_64-DVD-2009.iso，保留对应 sha256sum.txt 和签名 |
| TurboVNC 3.0.1 | [官方发布记录](https://github.com/TurboVNC/turbovnc/releases/tag/3.0.1)，分别准备 Linux 服务端及 Windows Viewer 适用材料 |
| VirtualGL | [官方文档](https://virtualgl.org/Documentation/Documentation)与[发布记录](https://github.com/VirtualGL/virtualgl/releases)，先确认内网版本及 CentOS 7 二进制兼容性 |
| 桌面兼容性 | [TurboVNC 桌面兼容性](https://turbovnc.org/Documentation/Compatibility30)；仍需测试同账号多 GNOME 会话 |

CentOS 7 已结束维护，Vault 是归档源且不提供新的安全更新。本环境用于旧系统兼容性复现。若 yum mirrorlist 不可用，应备份 repo 文件后使用对应版本的可信归档源，保持软件包签名验证，不用关闭证书/GPG 校验的办法绕过错误。

PowerShell 校验 ISO 示例：

```powershell
Get-FileHash 'D:\vnc-lab\downloads\CentOS-7-x86_64-DVD-2009.iso' -Algorithm SHA256
```

将结果与官方对应文件逐字比对，不使用文档中臆造的固定哈希。ISO/RPM/VM 磁盘不上传源码仓库。

## 4. 安装 CentOS 7

1. 创建 x86_64 Linux 虚拟机，挂载 DVD；根据虚拟机版本和宿主 GPU 能力评估启用 3D 加速，记录设置。
2. 安装 GNOME 桌面，设置时区和网络；创建用于 Worker/VNC/任务的同一普通账号。密码和 root 凭据不写入文档。
3. 配置 SSH，确认 Windows PowerShell 可以连接来宾机；提权只用于安装和系统配置。
4. 准备归档软件源，按需安装 open-vm-tools、X11 检查工具、D-Bus、字体和图形依赖；以实际 RPM 依赖检查结果为准。
5. 确认 SSH、DNS、时间、图形登录和磁盘正常，创建“基础系统”快照。

## 5. 单桌面与 VirtualGL

1. 安装匹配 CPU 架构/系统库的 TurboVNC 3.0.1 与已确认版本 VirtualGL RPM；记录 rpm -q 结果。
2. 先使虚拟机控制台的 Xorg/图形驱动可用。检查 glxinfo -B 的 vendor/renderer/OpenGL 版本；按 VirtualGL 版本官方指南配置 GLX 或 EGL 后端及账号权限。
3. 不假设宿主 NVIDIA 驱动可直接用于来宾虚拟显卡。VMware 虚拟图形栈与真实 GPU 环境不同；能否硬件加速必须实际检测。
4. 按 gnome-desktop.md 备份 xstartup 并替换模板。先启动单个 DISPLAY，再执行 DISPLAY=:1 xset q，通过 Viewer 连接确认窗口可操作。
5. 在 VNC 桌面内用已配置后端运行 VirtualGL 随包示例（如 /opt/VirtualGL/bin/glxspheres64，经 vglrun 启动）；检查画面及渲染输出，记录 3D 渲染目标。工具是否存在以安装版本为准。
6. 发现 llvmpipe/软渲染时明确记录，不能把软件渲染成功认定为 GPU 加速成功。不要在未确认正确 DISPLAY 和 Xauthority 前全局放开 X11 访问。

VirtualGL 配置成功、示例可运行与生产 GPU 性能验收是不同结论，须分别记录。不要把所有 GNOME 或任务一律包裹 vglrun；按实际应用需要验证。

## 6. 多桌面与项目联调

1. 用 vnc_manager.sh create -n 2，再扩展到 4；验证同账号 :1～:4、GNOME/D-Bus 和 Xauthority，断连重连后检查未锁屏。
2. 按 deployment.md 部署 API/Redis/PostgreSQL；可以放在另一台受维护系统上。API 的容器默认本地绑定端口，跨虚拟机访问需要受控调整。
3. 准备兼容 CentOS 7 的 Python/打包环境，构建并安装 Worker。先测试 echo、sleep、xeyes，再接入 Squish/AUT。
4. 验证不同 DISPLAY 的窗口、并发、取消、超时、清理、断网、桌面恢复与 Worker 重启。
5. 日志上传需共享路径和文件服务；无真实文件服务时仅能验证空 ID 行为或单独安排替身测试，不能宣称真实服务已通过。
6. 保存“图形链路通过”和“调度通过”快照，按 acceptance.md 逐项填写证据。

## 7. 最终交付与需要人工参与的步骤

交付安装版本表、配置模板、安装与验证命令、问题记录、渲染器证据、并发/清理测试结果。真实密码、许可证和未脱敏日志不进入 Git。

BIOS 设置、账号验证码、许可协议确认、UAC 提权及 Windows 重启可能需要用户操作；其余可优先通过 PowerShell、无人值守安装和 SSH 推进。若缺少 Squish/AUT 材料，明确将真实业务验收标记为未执行。
