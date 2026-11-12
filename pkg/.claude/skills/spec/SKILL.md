---
name: spec
description: 给新专案或大功能先写 spec（目标、非目标、场景、架构、对外契约、风险、验收、分批），再拆成带依赖的任务卡，让用户一次确认。需求大到 /task-align 一张或三张卡装不下时使用：新专案、跨多个模块的功能、重构、迁移。
argument-hint: <想法或需求描述>
disable-model-invocation: true
---

# /spec：先规划，再拆任务

需求：$ARGUMENTS

## 当前状态（自动注入）
!`python3 .claude/hooks/harness_lib.py context align`

## 前提
- 这是**规划**。在控制塔或审核对话里跑，最好用 plan 模式或 `HARNESS_MODE=groom`：只读代码，只写 `docs/specs/` 和 `.harness/`。
- 不写业务代码，不建分支。

## 步骤
1. **对齐（最多 5 个问题）**：一次问完，用 AskUserQuestion，推荐项放第一。只问会改变架构、范围或验收的问题，其余自己合理假设，并标注「推断」。先查 `.harness/decisions.md`。
2. **影响分析**：对已有代码调用 `impact-analyst`。全新专案改为写「技术选型」：每个选型 2 个候选，各写得失，给出推荐。
3. **写 spec**：`docs/specs/S-xxx-<slug>.md`（编号接着已有的往下编），控制在 2 页以内，章节如下：
   1. 目标（一句话，加上做完后用户能做到的 3 件事）
   2. 非目标（至少 3 条）
   3. 场景（3–6 个，用「谁在什么情况下做什么，得到什么」的写法）
   4. 架构：组件和职责、数据模型、对外契约（API、事件、schema），新专案再加目录结构
   5. 风险和对策；需要人判断的点（会变成人工门）
   6. 验收：全局验收标准，每条都要可验证。写成编号列表（`1. …`），编号就是它的 id：`S-xxx#1`、`S-xxx#2`…；看板「需求」页按这些编号显示每句需求的状态和证据
   7. 分批：任务清单，每个任务一行（编号、标题、规模、依赖、allowed_paths）
4. **拆任务卡**：按第 7 节为每个任务写卡（模板 `.harness/tasks/_TEMPLATE.md`）：
   - frontmatter 写 `spec: S-xxx`，依赖写进 `depends_on`；
   - 同一批里的任务，`allowed_paths` 不能互相重叠，`python3 .claude/hooks/harness_lib.py pick-batch` 会检查；
   - 每张卡 S 或 M 级，3–8 步；验收 A 要能对应回 spec 第 6 节：在验收项里写上它证明的是哪一条，例如 `- [ ] A1 刷新后保留倍速（S-xxx#2）`。
   - backlog 每张卡加一行，状态 `proposed`。
4b. **挑错**：按 spec 整体风险跑 `harness_lib.py critics <risk> spec`（新专案按 high），开 `critic` 子代理攻击 spec 和任务图，`judge` 核实，按 VALID 修改。门卡「机器已预检」写上挑错结果。
5. **一次确认**：开一张门卡 `/human-gate design 确认 S-xxx 和它的 N 个任务？`，frontmatter 写 `then: ready` 和 `then_tasks: [T-a, T-b, …]`。选项：
   - A：全部确认（推荐）
   - B：确认，但只先做第 1 批
   - C：要改（留言写改哪里）

   门卡正文附上 `python3 .claude/hooks/harness_lib.py waves` 的批次输出。
6. **告诉用户下一步**：确认后，白天执行用 `scripts/harness-loop.sh --parallel 2`，夜间用 `--until 06:00 --integration`。
