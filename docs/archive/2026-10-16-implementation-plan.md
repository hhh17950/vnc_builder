> 历史归档：保留需求演进和实施背景。路径已统一为 vnc_build；当前行为以 ../architecture.md 和源码为准。文中的提交号、测试数量和交付包不是本次发布记录。

# 本次实施计划：任务链路简化 + 日志上传

> 日期：2026-10-16
> 范围：`vnc_schdule_api`、`vnc_worker`，少量 `vnc_build` 与文档
> 背景：在「一个任务只执行一次、失联不 requeue」的前提下，收敛任务状态机，去掉 attempt 层与冗余字段，新增任务日志上传到 file_management 服务

---

## 一、目标

1. 任务执行链路瘦身：删除 attempt 层、`slot_clean`、`input_path`、`result_path`、`result_summary`。
2. Worker 执行结束后把 `stdout_path`、`stderr_path` 回报给 API。
3. API 收到结果后同步上传日志到 file_management，并把文件 id 与路径写入任务的 `job_info`。
4. 状态机收敛为「失联等待 + deadline 兜底」；Worker 改为弹性启动与桌面自愈。

---

## 二、定稿契约

### 2.1 状态机

- 中间态：`queued`、`running`、`cancel_requested`、`timeout_requested`
- 终态：`succeeded`、`failed`、`cancelled`、`timed_out`、`unknown`
- 规则：
  - 失联（租约过期）不改任务状态，任务继续停留在 `running`，等待 Worker 回来补报。
  - `running` 到达 `deadline_at` → 置 `timeout_requested`，Worker 若存活则清理后报 `timed_out`。
  - `deadline_at + 60s` 仍无结果（含 `cancel_requested`/`timeout_requested` 未被确认）→ API 直接兜底 `timed_out`。
  - 人工 `unregister`、同 `worker_id` 新 `session` 接管 → 未完成任务置 `unknown`。
  - 一个任务只被授权执行一次，不 requeue；重试只能新建 `task_id`。

### 2.2 接口

| 方法与路径 | 请求 | 响应 | 变化 |
| --- | --- | --- | --- |
| `POST /api/v1/workers/{worker_id}/claim` | `{session_id, slot_id, task_id}` | `{command, cwd, deadline_timestamp}` | 去 `attempt_id`、`input_path` |
| `POST /api/v1/workers/{worker_id}/tasks/{task_id}/result` | `{session_id, status, stdout_path, stderr_path, error}` | 任务状态 | 去 `attempt_id`、`slot_clean`，加两个路径 |
| `POST /api/v1/tasks` | `{command, cwd, timeout_seconds}` | 任务视图 | 去 `input_path` |
| `GET /api/v1/tasks/{id}` | - | 任务视图 | 去 `input_path`、`current_attempt_id`，加 `job_info` |
| `GET /api/v1/tasks` | 分页 | 任务视图列表 | 同上 |
| `POST /api/v1/tasks/{id}/cancel` | - | 202 + 任务视图 | 不变 |
| `POST /api/v1/workers/register` | 不变 | 租约秒数 | 不变 |
| `POST /api/v1/workers/{worker_id}/heartbeat` | 不变 | `{cancel_task_ids}` | 不变 |
| `POST /api/v1/workers/{worker_id}/shutdown` / `unregister` | 不变 | 状态 | 语义改为置 `unknown` |
| `GET /api/v1/workers` | - | 大盘快照 | 不变 |

### 2.3 数据结构

- `tasks` 新增：`worker_id`、`session_id`、`slot_id`、`started_at`、`deadline_at`、`finished_at`、`job_info(JSON)`。
- `tasks` 删除：`input_path`、`current_attempt_id`。
- `job_info = {"stdout_path": ..., "stderr_path": ..., "stdout_id": ..., "stderr_id": ...}`。
- 删除 `task_attempts` 表。

### 2.4 file_management

- 配置项只有 `VNC_FILE_MGMT_URL`；留空则跳过上传。
- 占位契约：`POST {VNC_FILE_MGMT_URL}`，multipart 字段 `file`，响应 `{"id": "..."}`。
- 代码收敛为 `upload(path) -> file_id` 一个函数，真实格式变化只改这一处。

---

## 三、任务清单

### A. API（`vnc_schdule_api`）

**A1 协议模型** —— `src/schemas/protocol.py`

- `ClaimResult` 保留 `command/cwd/deadline_timestamp`，删 `attempt_id`、`input_path`。
- `ResultRequest` 删 `attempt_id`、`slot_clean`，新增 `stdout_path`、`stderr_path`（可空）。
- `TaskCreate`、`TaskView` 删 `input_path`；`TaskView` 删 `current_attempt_id`、新增 `job_info`。
- 验收：OpenAPI 中不再出现被删字段；契约字段测试更新。

**A2 数据模型** —— `src/models/tables.py`

- `Task` 增加执行字段与 `job_info`，删除 `input_path`、`current_attempt_id`。
- 删除 `TaskAttempt` 类。
- 验收：导入无错，字段与迁移 0006 一致。

**A3 业务逻辑** —— `src/services/tasks.py`

- `claim_task`：
  - 保留 Worker/session/租约/slot 注册校验。
  - 任务行加锁；若任务已 `running` 且 `worker_id/session_id/slot_id` 与请求一致 → 返回任务行上原有的 `command/cwd/deadline_timestamp`（处理 claim 响应丢失的重试）。
  - 否则要求 `queued`，一个事务内置 `running` 并写 `worker_id/session_id/slot_id/started_at/deadline_at`。
  - 其余情况 409。
- `finish_task`（校验与幂等，按此顺序）：
  1. 任务不存在 → 404。
  2. 任务已是终态 → 直接返回当前状态（幂等）。
  3. `session_id` 不等于任务行上的值 → 409。
  4. 任务状态必须是 `running/cancel_requested/timeout_requested`，否则 409；`cancel_requested` 只接受 `cancelled`，`timeout_requested` 只接受 `timed_out`（各自优先）。
  5. 通过后写 `status/finished_at/error/job_info` 的两个 path；**不校验租约**（允许抖动恢复后补报）。
- 验收：`test_task_flow` 覆盖 claim 去重、重复 finish 幂等、取消/超时竞争。

**A4 对账循环** —— `src/services/dispatch.py`

- 删除「租约过期把任务标 lost」的逻辑，租约过期只清 Worker 的 slots 快照。
- 超时：`deadline_at <= now` 且状态 `running` → `timeout_requested`；`deadline_at + 60s <= now` 且仍非终态 → 直接 `timed_out`。
- 保留：长期 `queued` 重新投递、Redis PEL 恢复。
- 验收：新增 deadline 兜底与租约不过期改状态的用例。

**A5 人工放弃** —— `src/services/workers.py`

- `_mark_worker_offline`（`unregister` 与新 session 接管）写 `unknown`，替换 `lost`。
- 验收：对应用例断言 `unknown`。

**A6 文件服务客户端** —— `src/services/file_management.py`（新增）

- `upload(path: Path) -> str`：`POST {VNC_FILE_MGMT_URL}` 上传 multipart 字段 `file`，解析 `{"id": ...}`；未配置 URL 抛特定异常或返回空由调用方决定。
- 网络错误与非法响应封装为明确异常。
- 验收：用假 HTTP 断言请求体与返回值。

**A7 上传编排** —— `src/services/tasks.py`（`finish_task` 内，同步）

- 先在事务里提交任务终态与 `job_info` 的两个 path（`id` 为空）。
- 提交后按共享路径读取两个文件并上传，回填 `stdout_id/stderr_id` 再提交。
- 任一步失败只记日志，`id` 留空，**不改变任务终态，不做补传**。
- 验收：上传成功与失败两条路径各有用例。

### B. Worker（`vnc_worker`）

**B1 执行器** —— `src/services/executor.py`

- 删除 `input_path` 参数与 `VNC_INPUT_PATH` 相关逻辑。
- `ExecutionResult` 增加 `stdout_path`、`stderr_path`；`run()` 返回实际日志绝对路径。
- 验收：`test_runtime` 断言日志路径与内容。

**B2 结果回报** —— `src/services/worker.py`

- `_handle` 构造 payload：`{session_id, status, stdout_path, stderr_path, error}`。
- `_report` 删除 attempt_id、spool 参数与落盘；幂等交给 API 的任务终态判断。
- 本地 `cleanup_confirmed` 隔离逻辑保留，不上报。
- 验收：相关用例更新。

**B3 claim 适配**

- `ClaimResponse` 删除 `attempt_id`、`input_path`。
- `_claim` 的重试与 409 处理逻辑不变。

**B4 弹性启动与桌面自愈**

- `initialize`：至少 1 个健康 slot 即启动并注册当前可用 slot；0 个才失败。
- `reconcile_vnc_once`：在修复现有 slot 之外，补齐 `1..slot_count` 中缺失的 slot，成功后追加进 `self.slots` 并重新注册。
- 验收：新增「部分 slot 启动」「恢复循环补齐 slot」用例。

### C. 迁移（`vnc_schdule_api/alembic`）

**C1 `0006_merge_attempts_and_job_info`**

- `tasks` 增加执行字段与 `job_info`，删除 `input_path`、`current_attempt_id`。
- 数据回填：存量 `lost` → `unknown`；存在未完成 attempt 的任务归 `unknown`。
- 删除 `task_attempts` 表。
- 验收：测试库 `alembic upgrade head` 通过，`downgrade -1` 可回退。

### D. 测试

- D1 Worker：回报 payload、日志路径、部分启动、补齐 slot。
- D2 API：claim 去重、finish 幂等与状态竞争、deadline 兜底、`unknown`、`job_info` 上传成功/失败。
- D3 全量回归：Worker、API、Builder 三套测试全绿。

### E. 文档

- E1 更新 `项目交接文档.md`、三个 README、`vnc_worker/deploy/centos7_acceptance.md`。
- E2 更新 `.env.example` 与 `vnc-worker.env.example`，新增 `VNC_FILE_MGMT_URL`。

### F. 配置

- F1 API 新增 `VNC_FILE_MGMT_URL`（可选，留空跳过上传）；其余配置不变（租约保留）。

---

## 四、注释规范（企业级）

1. 模块头：每个模块有模块级 docstring，写清职责、边界与依赖。
2. 函数：所有 public 函数/方法必须有 docstring，说明用途、参数、返回值、可能抛出的异常；涉及副作用的函数（如上传、写库、杀进程）明确标注。
3. 过程注释：用「为什么」解释状态跃迁、并发与加锁、去重与幂等、进程组清理、边界与容错，不复述代码本身。
4. 不变量：在代码处标明协议不变量（如「一个任务只被授权一次」「终态不可逆」），便于后续维护。
5. 风格：与现有代码保持一致的中文注释风格；类型注解全覆盖。
6. 目标：不存在未注释的关键分支；注释行占比 ≥ 20% 作为参考指标，以「覆盖完整、说明动机」为准。

---

## 五、实施顺序

1. A1 / A2 + C1：先固定协议模型与迁移。
2. A3 / A4 / A5 / A6 / A7：服务逻辑与上传。
3. B1 ~ B4：Worker 改造。
4. D：测试补齐与回归。
5. E / F：文档与配置。
6. 全量回归：三套测试 + 测试库迁移。

---

## 六、验收标准

- Worker、API、Builder 三套测试全部通过；测试库迁移到 `0006`。
- claim 去重、finish 幂等、deadline 兜底、`unknown`、`job_info` 上传（成功/失败）均有测试覆盖。
- 文档与代码一致，`.env.example` 已更新。

---

## 七、风险与取舍

- 同步上传会占用结果回调耗时；上传失败不补传，`job_info` 的文件 id 可能为空（已确认接受）。
- 去掉 attempt 层后不再支持同任务多次执行；需要重试只能新建 `task_id`。
- 弹性启动后短时间内可用 slot 可能少于 `slot_count`，容量是渐进恢复的。

---

## 八、本次范围外

- Worker 匿名化 / 去除 session 与租约的改造。
- 退出码落盘与崩溃后结果找回。
- 日志上传的补传、重试队列。
- CentOS 7 真机验收（另行排期）。
