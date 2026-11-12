---
name: backlog-groom
description: 审核对话专用：当 backlog 没有 ready 任务时，从现有代码出发，按功能完整性、测试、安全与资安、依赖与密钥、部署与 CI、性能、可观测性、UX 与无障碍、文档九个维度找缺口，生成带优先级/风险/规模的任务提议并写入 backlog 提议区。用户说「任务清空了」「还能优化什么」「审核一下项目」时使用。
argument-hint: [可选：聚焦维度，例如 security deploy]
disable-model-invocation: true
---

# /harness:backlog-groom：审核扩展任务

聚焦：$ARGUMENTS（为空 = 全部维度）

## 前提
- 应在**主仓库根目录的独立会话**中运行（不是执行任务的对话），以避免执行者给自己出题、也避免 worktree 中多处写 backlog。
- 这一步只读代码、只写 `.harness/backlog.md` 提议区和 `.harness/tasks/` 新卡，不改业务代码。

## 当前状态（自动注入）
!`python3 ${CLAUDE_PLUGIN_ROOT}/hooks/harness_lib.py context groom`

## 步骤
1. **收集**：先把各交接包「遗留问题」和任务卡「发现的问题」中尚未进 backlog 的条目整理出来（这些优先级最高，因为是实际做的时候发现的）。
1b. **看原始数据，而不是只看代码**：如果有 `.harness/sources.md`，按它列的来源去读（错误日志、崩溃目录、监控导出、`gh issue list` 查询、用户反馈文件）。让数据告诉你先修什么，而不是等人一条条转给你。每条提议附上数据证据（例如「近 7 天 /offer 500 共 37 次」）。
2. **并行审计**：同时调用两个子代理：
   - `backlog-reviewer`：功能完整性、测试缺口、部署与 CI、性能、可观测性、UX 与无障碍、文档。
   - `security-auditor`：认证授权、输入校验、密钥、依赖漏洞、供应链、安全头、日志中的敏感信息。
3. **合并去重**：与 backlog 现有条目和 `decisions.md`（已被否决的不再提）去重。
4. **打分**：每条给 `priority`（P0–P3）、`risk`、`size`、`auto_ok`。
   - `auto_ok: yes` 仅限：补测试、补文档/注释、lint/格式修复、依赖 patch/minor 升级且有测试覆盖、增加日志/指标但不改行为。
   - 其余一律 `auto_ok: no`。安全类 P0 也是 `no`（要人知道）。
5. **写入**：
   - 每条在 backlog「AI 提议区」加一行，status `proposed`（`auto_ok: yes` 的直接 `ready`）。
   - P0/P1 以及所有 `auto_ok: yes` 的条目，按任务卡模板生成精简版任务卡（目标、范围、验收 A、allowed_paths、risk）；其余只留 backlog 行，被批准后再 `/harness:task-align`。
   - 最多新增 10 条，宁缺毋滥；每条必须指向具体文件/位置作为证据。
6. **批准门**：把所有 `auto_ok: no` 的提议汇成**一张** `/harness:human-gate design 批准以下提议？` 门卡，选项：A 全部批准 / B 只批准 P0–P1 / C 逐条（在备注中写 `批准 T-a,T-b；否决 T-c`）。
6b. **从你的决定里提炼原则**（每次 groom 做一次）：
   - 读 `.harness/decisions.md` 和已答复的门卡，找出你**反复**做出的同类选择（至少 3 次），写成一句可执行的原则（例如「语音类一律选变速不变调」「UI 默认分段按钮而非下拉」）。只写有 3 个以上决定支撑的，附上决定编号。
   - 再找一两条你**没说出口、但决定里一直体现**的偏好，标注「推断」。
   - 汇成一张 `/harness:human-gate design 采纳这些原则？` 门卡，`then_rules:` 写原则列表，选项 A 全部采纳 / B 只采纳有 3 个以上决定支撑的 / C 都不要。
   - 跑 `python3 ${CLAUDE_PLUGIN_ROOT}/hooks/harness_lib.py trust`，有「建议放权」的类别就写进输出，提醒用户可以自己执行放权命令。
7. **输出**：表格列出新提议（编号、标题、P、risk、size、auto_ok、证据位置），以及门卡编号。
