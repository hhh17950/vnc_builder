# 原始需求与确认基线

整理日期：2026-10-18。
来源：工作区上版交接文档、2026-10-16 实施计划及本次对话。没有单独提供更早的原始需求原稿，本文是可追溯的整理版，不伪称逐字原稿。历史材料在 archive/ 中保留。

## 业务目标

在多台机器上并行运行 Squish 等 GUI 自动化任务。每台机器一个 Worker，一个 Linux 账号运行 1～4 个 TurboVNC 桌面，每个桌面对应一个 Slot，任一 Slot 同时只运行一个任务。

## 原始运行约束

| 主题 | 要求 |
| --- | --- |
| 环境 | CentOS 7、TurboVNC 3.0.1、GNOME；VirtualGL 按真实环境适配 |
| 仓库 | API、Worker、构建部署三仓库独立管理 |
| 账号 | Worker、VNC 和任务同一账号；运行中不 su、不等待交互密码 |
| 任务 | command 参数数组、绝对 cwd、可选 timeout_seconds；不做 Shell 展开 |
| 并发 | 健康且空闲 Slot 才领任务，启动前必须获得 API 授权 |
| 桌面 | 启动补齐；独立周期检查和恢复空闲桌面；执行中不重建 |
| 取消 | API 先记录请求，心跳持续下发，Worker 清理后确认 |
| 超时 | 默认 7200 秒，从授权开始；排队不计时 |
| 输出 | stdout/stderr 分开持续落盘到 cwd/job_log；服务日志按日与 100 MB 分片，压缩保留 30 天 |
| Squish | 任务脚本启动 Server/Runner/AUT，自行避免并发端口冲突 |
| 信任边界 | 内网使用，当前 Worker API 没有 Token 鉴权 |

## 后续已确认改造

1. 一个 task_id 只授权执行一次，失联不 requeue，重试创建新任务。
2. 删除 task_attempts，把执行归属和时间字段直接存到 tasks。
3. 中间态 queued/running/cancel_requested/timeout_requested；终态 succeeded/failed/cancelled/timed_out/unknown。
4. 租约过期不直接改任务；deadline 后请求超时清理，deadline + 60 秒无结果兜底 timed_out。
5. 强制注销、新 session 接管时，旧未完成执行归 unknown。
6. 结果回报两个日志路径；API 同步上传文件服务，记录 job_info 的路径与文件 ID。上传失败不改终态、不补传。
7. 目标是部分健康桌面即可启动，后续渐进补齐；实际实现限制在 architecture.md 中列出。

## Windows 虚拟机验证需求

在 Windows 上准备 VMware 和 CentOS 7，安装 GNOME、TurboVNC、VirtualGL；验证 DISPLAY、OpenGL 渲染路径、多桌面、防锁屏以及完整调度链路。Squish 和被测应用的真实验证依赖用户提供安装包、许可证和脚本。准备清单见 windows-vm.md。

## 本次仓库交付要求

三个 GitHub 仓库命名 vnc_schdule_api、vnc_worker、vnc_build；各项目根目录只保留一个 README.md，描述结构和启动方式；系统级文档统一放在 vnc_build/docs/。上传源码、测试、迁移、必要静态资源及配置模板，不上传真实配置、凭据、缓存、日志、构建产物和虚拟机文件。

## 范围外

完整桌面基线回滚、任务自动重跑、崩溃后结果找回、日志补传、Redis Stream 自动裁剪、脱离任务进程组的进程治理，均未实现。生产 GPU 性能和真实 Squish 结果不能由虚拟机通用示例替代。
