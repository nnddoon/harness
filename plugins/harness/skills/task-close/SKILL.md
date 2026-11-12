---
name: task-close
description: 任务验收通过后的收尾：写交接包、追加冻结路径、开 PR 和合并人工门、更新 backlog，然后用选择题问用户下一个任务在本对话继续还是开新对话（附启动块）。任务进入 review、用户说「收尾」「这个做完了」「下一个」时使用。
argument-hint: <任务号；省略则从分支推断>
---

# /harness:task-close：收尾、交接、决定下一步

任务：$ARGUMENTS

## 当前状态（自动注入）
!`python3 ${CLAUDE_PLUGIN_ROOT}/hooks/harness_lib.py context close`

## 步骤

1. **前置检查**：任务卡 verifier 结论必须是 PASS，验收 A 全部勾选有证据；否则回到 `/harness:task-run`。未提交改动先提交。

2. **交接包**：按 `.harness/handoffs/_TEMPLATE.md` 写 `.harness/handoffs/T-xxx.md`。重点写清：
   - 对外契约（下游会依赖的接口、数据结构、事件、配置项、URL）。
   - **冻结清单**：本任务交付后，哪些文件/目录下游任务不应再改（公共 API、schema、已验收 UI 组件、协议）。只冻结真正的契约，不要把整个模块锁死。
   - 「发现的问题」中的条目 → 作为 `proposed` 行加入 backlog 的「AI 提议区」（单写者：如在 worktree 中，写进交接包「遗留问题」，由控制塔或 `harness-loop.sh` 同步）。

3. **冻结**：把冻结清单**追加**到 `.harness/locks.txt`（只允许追加；hook 会拒绝修改已有行）。

4. **合并人工门**：推送分支，`gh pr create`（正文 = 交接包 1–5 节；没有 gh 就输出 PR 标题和正文）。然后 `/harness:human-gate irreversible 合并 T-xxx 到 main？`，门卡 frontmatter 填 `pr: <PR 号>`（PR 本身就是门：合并=批准）。**不要自己合并。** 任务状态保持 `review`；人批准并合并后才改 `done`（控制塔会话或 `harness-loop.sh` 会用 `python3 ${CLAUDE_PLUGIN_ROOT}/hooks/harness_lib.py sync-merged` 自动标记）。

5. **更新状态**：任务卡和 backlog 行（在主仓库时）更新为 `review`。

6. **问下一步**（交互式会话必须问；无人值守时按「默认」执行并在输出首行写明选择）：
   推荐由调度规则算，不要自己判断：
   - 下一张：`python3 ${CLAUDE_PLUGIN_ROOT}/hooks/harness_lib.py pick-batch 1`（空 = 没有可做的，推荐**开审核对话跑 /harness:backlog-groom**；若所有候选都依赖本任务合并或 open 门卡，推荐**先停**）。
   - 在哪做：`python3 ${CLAUDE_PLUGIN_ROOT}/hooks/harness_lib.py decide <下一张> --after <本任务> --context <你估计的上下文用量百分比>`，输出 `same` 或 `new` 加理由。

   用 AskUserQuestion 一次问：
   - Q1「下一步怎么走？」选项：推荐项（标「（推荐）」）、其余 2–3 项。
   - 如推荐的是具体任务，在问题里写上任务号和一句话理由。

7. **按选择执行**：
   - **本对话继续**：建议用户先 `/clear`（保留磁盘状态、丢掉旧上下文），然后 `/harness:task-run T-yyy` 或先 `/harness:task-align T-yyy`。如需换分支，先确认工作区干净再 `git switch`。
   - **开新对话**：输出交接包第 7 节「新对话启动块」，必须包含：`scripts/new-task.sh T-yyy` 命令、`cd` 路径、分支名、第一句提示词（含必读文件、冻结路径、复述要求）。
   - **审核对话**：输出：`cd <主仓库根>` → `HARNESS_MODE=groom claude` → `/harness:backlog-groom`（审核模式下 hook 只允许写 `.harness/`）。
   - **先停**：列出等待中的门卡编号和 `scripts/gates.sh`。
