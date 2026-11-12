---
name: task-align
description: 把一个新需求对齐成可执行的任务卡（目标、范围、修改过程、验收标准、guardrail、人工门、分支/worktree 建议）。在用户提出新功能、改动、bug 修复需求，或说「对齐需求」「写任务卡」「先别写代码」时使用。
argument-hint: <需求描述 或 backlog 中的任务号>
---

# /harness:task-align：需求 → 任务卡

输入：$ARGUMENTS

## 当前状态（自动注入）
!`python3 ${CLAUDE_PLUGIN_ROOT}/hooks/harness_lib.py context align`

## 步骤

1. **定位**：如果输入是任务号（如 T-007），读 `.harness/backlog.md` 和已有任务卡；否则视为新需求，分配下一个编号（已有最大编号 + 1，三位数）。

2. **影响分析（只读，不改代码）**：调用 `impact-analyst` 子代理，交给它需求描述、`.harness/locks.txt` 和相关交接包。
   - **bug 修复**：用轻量模式，必须找到能复现的测试或复现步骤。
   - **新功能**：用完整模式。
   - 把它的输出填进任务卡第 3 节的「影响分析」表。**`allowed_paths`、`locked_paths`、第 6 节 guardrails、`risk`、`size` 都从这张表推出来**，不要凭感觉填。
   - 碰到冻结路径 → 计划一张 `unlock` 门卡；要加依赖 → 也是 `unlock`；碰到对外契约 → guardrails 写明「保持兼容」或开 `design` 门卡。
   - 需求大到 3 张卡以上，或者跨 3 个以上模块 → 停下，建议用户改用 `/harness:spec`。

3. **对齐（最多 3 个问题）**：只问会显著改变方案或验收的问题；其余自己做合理假设并写进「需求对齐记录」标注「推断」。
   - 交互式会话：用 AskUserQuestion 一次问完（每题 2–4 个选项，推荐项放第一并标「（推荐）」）。
   - 先查 `.harness/decisions.md`，已决定的不再问。
   - 需求清楚时可以 0 个问题。

4. **写任务卡**：复制 `.harness/tasks/_TEMPLATE.md` 到 `.harness/tasks/T-xxx-<slug>.md` 并填写全部章节。要点：
   - **范围**：「不做」至少写 1 条，防止范围蔓延。
   - **allowed_paths**：尽量窄；包括测试目录。
   - **修改过程**：3–8 步，每步可独立验证；最后一步是完整验证。
   - **验收 A**：每条都有可执行的验证命令；必含「已有测试全过且未被删除/跳过」和「只改了 allowed_paths」。
   - **验收 B**：凡属 `.claude/rules/human-gates.md` 中 ui / sensory / design 类判断的，列在这里。
   - **Guardrails**：写清楚本任务不许碰的契约（来自交接包）和不许引入的东西。
   - **risk**：照抄影响分析的结论（涉及鉴权、用户输入、文件上传、支付、外部 webhook、密钥 → `high`）。
   - **test_owner**：默认 `tester`，测试只能由 tester 子代理写。只有一两行的小修复，并且你在对齐时明确说明了，才写 `any`。
   - **size L** → 建议拆分成多张卡，并说明拆法。
   - **session**：保持 `auto`。在哪个对话执行由调度规则统一决定（`python3 ${CLAUDE_PLUGIN_ROOT}/hooks/harness_lib.py decide T-xxx`），你只负责把 `size` 和 `allowed_paths` 填准——规则就是看这两项。只有用户明确要求时才写 `same` / `new`。

5. **登记**：在 `.harness/backlog.md` 加一行（或更新已有行），status 保持 `proposed`。

6. **挑错再确认**（`risk: medium/high`）：跑 `harness_lib.py critics <risk> spec`，按角度开 `critic` 子代理攻击任务卡（影响范围漏了什么、验收能不能证明需求、范围该不该拆），交 `judge` 核实，按 VALID 修改任务卡。在给用户的摘要里写一行「N 个挑错，K 条成立已改」。
7. **确认**：向用户展示任务卡的「目标 / 范围 / 验收 A+B / guardrails / session 建议」摘要（不超过 15 行），问：「确认后我把状态改为 ready。要改哪里？」
   - 用户确认 → 任务卡和 backlog 改为 `ready`，然后跑 `python3 ${CLAUDE_PLUGIN_ROOT}/hooks/harness_lib.py decide T-xxx --after <当前对话刚做完的任务号，没有就省略>`，按结果告诉用户下一步：
     - `same` → `/clear` 后 `/harness:task-run T-xxx`
     - `new` → `scripts/new-task.sh T-xxx`，按它打印的启动块开新对话；或交给 `scripts/harness-loop.sh` 自动派发。
   - 不要在用户确认前开始写代码。
