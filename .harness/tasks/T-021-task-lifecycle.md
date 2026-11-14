---
id: T-021
title: 任务不自锁、解锁后接续
status: ready
priority: P0
risk: high
size: M
source: human
spec: S-003
test_owner: tester
branch: task/T-021-task-lifecycle
worktree: .claude/worktrees/T-021
session: auto
depends_on: [T-018, T-020]
context_files: [docs/specs/S-003-field-fixes.md, docs/feedback/s002-field-test.md]
allowed_paths: [pkg/.claude/hooks/harness_lib.py, pkg/.claude/hooks/protect_paths.py, pkg/.claude/hooks/gate_github.py, pkg/.claude/hooks/guard_bash.py, pkg/.claude/skills/task-align/SKILL.md, pkg/.claude/skills/human-gate/SKILL.md, pkg/scripts/harness-loop.sh, pkg/tests/test_lifecycle.sh, pkg/scripts/test-harness.sh, plugins/harness/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-021 任务不自锁、解锁后接续

## 1. 背景与目标
任务因 locked_paths 含 .harness/** 被自己锁死（F-9）；解锁门卡批准后任务不接续（F-12）；guard_bash 把 heredoc 新建门卡误判成写答案。答复后能接续的只有 waiting_human；replan 开的 ambiguity 门卡和 unlock 门卡都让任务停在 blocked，答复后没有出口（见 project 文档 S-003-adjustments）。

## 2. 范围
**做：**
- task-align 不把 .harness/** 写进 locked_paths；protect_paths / control-diff / T-018 的 denyWrite 永远放行本任务自己的卡、交接包、门卡
- unlock 门卡快照必须带 paths，否则拒绝快照并提示
- 记录 unlock 批准后按快照任务把 blocked 转 ready 并排接续；调度器重新派发已批准解锁的 blocked 任务
- blocked / waiting_human 的任务在其门卡全部答复后（unlock 已批准或 ambiguity 等已答复），任务卡与 backlog 两份一起转 ready
- 批准的 unlock 也放开任务卡 locked_paths 中被批准的路径（T-018 §8 移交）
- 测试以 project 文档 S-003-adjustments 的复现脚本 S-2 为起点
- guard_bash：新建门卡文件（无 answer 内容）不再被当作写答案

**不做（明确排除）：**
- 不放宽答案库只由控制面写的规则

## 接口约定（tester 第 1 轮；测试：`pkg/tests/test_lifecycle.sh`）

**① 任务自己的文件（F-9，A1）**
- 新函数 `H.own_task_paths(tid) -> list[str]`（tid 不是 `T-\d{3,}` → `[]`），glob 为：
  `.harness/tasks/<TID>.md`、`.harness/tasks/<TID>-*.md`、`.harness/handoffs/<TID>.md`、`.harness/handoffs/<TID>-*`、`.harness/handoffs/<TID>/**`、
  `.harness/gates/G-<T123>-*`、`.harness/gates/G-<T123>-*/**`（`<T123>` = 任务号去掉横线）。用 `H.matches_any` 匹配。
  边界：T-201 的不匹配 `T-2010-x.md`、`G-T2010-1.md`、`G-T202-1.md`。
- `protect_paths.py`：规则 4 的 **任务 locked_paths** 部分对 own_task_paths 命中的路径不生效（locks.txt 全局冻结不变）；其余规则照旧。
  例：卡 `locked_paths: [.harness/**]`、`allowed_paths: [src/**]`，在 worktree 写 `.harness/tasks/T-201-x.md`、`.harness/handoffs/T-201.md`、`.harness/gates/G-T201-2.md`、`.harness/gates/G-T201-2/shot.png` → 放行；`.harness/gates/G-T202-1.md`、`.harness/tasks/T-2010-x.md`、`.harness/decisions.md` → 仍 deny（locked_paths）。
- `control_diff(..., task=TID)`：改动文件命中 own_task_paths(TID) 时**不算 locked_paths 命中**（CONTROL_PATHS / 验证入口照算）；别的任务的卡、`.harness/backlog.md` 等仍算。
- `strict_settings(root, "task", TID)`：denyWrite 里没有任何条目等于或是 own 路径（存在或尚不存在）的上级目录；没有任何 `Edit(...)`/`Write(...)` deny 规则的 glob 匹配 own 路径。某条 locked glob 会覆盖 own 路径时，改为列出它现在匹配的**已存在文件减去 own 文件**（每个文件一条 denyWrite + Edit/Write 规则）；例：`.harness/**` 时现存的 `.harness/notes.md` 仍被拒（denyWrite 与 Edit/Write 都有）。尚不存在的非 own 文件由 control-diff 兜底。
- task-align SKILL：有一行同时含 `locked_paths`、`.harness/**` 和「不」（不要把 `.harness/**` 写进 locked_paths），并说明任务自己的卡 / 交接包 / 门卡永远可写。

**② unlock 门卡必须带 paths（F-12，A2）**
- 快照的 `paths`（kind 为 unlock）：取门卡 frontmatter `paths:`（列表或标量；每项按 `_good_lock` 规范化：相对路径、不含 `..`、`X/` → `X/**`，不合格的丢弃）；为空时退回任务卡 `unlock:`（v0.2 兼容，现有测试依赖）；仍为空且门卡号是任务门卡（`task_of_gid` 非空）且不是 `G-Txxx-ctl` → **不快照**：`snapshot_meta` 返回 None、不写 `<GID>.meta.json`，因而 `record_answer` / `answer_gate` 返回 False、不记录。
- 新函数 `H.unlock_paths_missing(main, gid) -> str`：上述情形返回一句提示，否则 `''`。提示须含门卡号、`paths:` 和写法示例 `paths: [`。
- CLI：`harness_lib.py answer <GID> A` / `show <GID>` 遇到此类门卡 → 退出 2，stderr 含上述提示（门卡号 + `paths:`），答案库无记录。gate-sync（`sync_once`）把同一提示写进日志（不另测）。
- 之后给门卡补上 `paths:`（仍未快照、未答复）→ 下一次见到正常快照，答复可记录。
- human-gate SKILL：有一行同时含 `unlock` 与 `paths:`（unlock 门卡必须写 `paths:`）；答复处理段有一行同时含 `blocked` 与 `ready`。

**③ 答复后接续（F-12 / S-2，A2）**
- `settle_answer` 在写完镜像后：若 meta 的 task 非空、门卡不是 `G-Txxx-ctl` / 合并门卡、`then` 不是 ready（那条路径照旧），且任务**处于 blocked**（门卡所在 checkout 的任务卡 `status: blocked`，或主仓库 backlog 行是 `blocked`），且本次答复「放行」（kind ∈ APPROVAL_KINDS 时须是 A；其他 kind 任何字母），且该任务在门卡所在 checkout 与主仓库都没有 open 门卡 →
  门卡所在 checkout 的任务卡、主仓库任务卡（若是另一个文件且存在）、主仓库 backlog 行**都改为 `ready`**；返回 `(status, TID)`；**不写** `.resume`（由调度器 pick-batch → new-task.sh 复用 worktree 派发，避免跑两次）。
- unlock 答 B（rejected）→ 卡与 backlog 都保持 `blocked`；还有 open 门卡 → 保持 `blocked`。
- `waiting_human` 照旧：卡转 `in_progress` + `.resume`（`take_resumes` 交出一次）。见 §9。
- 终端 `answer` 成功行含任务号与 `ready`（例：`✓ G-T002-1：A → approved；T-002 转为 ready，调度器下一轮派发`）。
- `pick_batch(main, n)` / `harness_lib.py pick-batch N`（在主仓库跑）随后包含该任务。

**④ 批准的 unlock 放开 locked_paths（T-018 §8 finding 7）**
- 来源只有 `H.approved_unlock_paths(main, TID)`（答案库里 A、task/kind 来自快照）；门卡 `status: approved`、别的任务的批准都不算。
- `strict_settings(task, TID)`：locked glob P 等于某条已批准 unlock 路径（`_norm` 后），或 P 无通配且被某条已批准路径匹配 → 该项不进 denyWrite、不生成 Edit/Write 规则；其他 locked 项照旧。
- `control_diff(task=TID)`：命中 locked glob 的文件若也匹配某条已批准 unlock 路径 → 不算命中（即「unlock 快照路径 ∩ locked_paths」才放行）。
- protect_paths 已按 approved_unlock_paths 放行，不变。

**⑤ guard_bash 与 heredoc（A3）**
- 由 `cat` 或 `tee` 读取的 heredoc 正文是文件内容：NEVER_RAW 规则对去掉这些正文后的命令检查（可复用 `H.drop_heredocs` 的思路）；喂给 bash / sh / python3 等解释器的 heredoc 正文照旧全文检查（`bash <<EOF … harness_lib.py answer G-x A … EOF` 仍 deny）。
- 新增：用 `cat`/`tee` heredoc 写 `.harness/gates/G-*.md`，正文里有 frontmatter 行 `answer:` 且值非空（去掉 `#` 注释后）→ deny，理由含「答案库」。`answer:` 为空或只有注释 → 不因此拒绝。

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 为什么 F-12 发生 | 门卡由会话用 Bash 绕过手写，paths 为空，控制面无法关联 | 现场报告 F-12 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | answers settle、pick-batch、protect_paths、task-align 文案 | - |
| 风险 | high：门卡语义 | - |

## 4. 修改过程（计划 → 执行日志）
- [x] 1. tester 写失败测试 — 结果：pkg/tests/test_lifecycle.sh 39/101（红）；test_answers.sh G-T101-13 补 paths 夹具
- [x] 2. 实现 — 结果：test_lifecycle 101/101；test-harness 327/327；其余 pkg/tests/test_*.sh 全 N/N
- [ ] 3. 挑错 — 结果：
- [ ] 4. verifier — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. task-align 生成的卡 locked_paths 不含 .harness/**；任务能写自己的卡、交接包、门卡（S-003#6） — 证据：
- [ ] A2. 没有 paths 的 unlock 门卡不会被快照，并给出提示；任务处于 blocked 或 waiting_human、它的门卡都已答复（unlock 已批准，或 ambiguity 等非审批类门卡已答复）时，任务卡和 backlog 两份都转为 ready，并被调度器派发；unlock、ambiguity 各一个测试，断言两份状态（S-003#8） — 证据：
- [ ] A3. heredoc 新建门卡不被 guard_bash 拒绝，写 answer 仍被拒 — 证据：
- [ ] A4. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A5. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- [ ] B1. 在你的 Mac 上：一个小任务从对齐到开 PR、合并门卡全流程跑通 — 门卡：

## 6. Guardrails（本任务特有）
- 答案仍只认答案库

## 7. 当前进展（中断/换对话时更新）
- 最后更新：2026-11-14（builder）
- 做到哪：实现完成，全部测试绿，插件已重建
- 下一步：挑错（risk high：critic × 5 → judge）、verifier
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- pkg/tests/test_publish.sh 在全量连续跑时出现过一次 137/139，单独重跑 3 次均 139/139（基线同样通过）：疑似时序抖动，未改。
- guard_bash：未加引号的 cat/tee heredoc 里，以裸 `harness_lib.py` 开头的反引号片段不检查（门卡模板「怎么答复」那行，库不在 PATH 上不可执行）；其他 `$(…)` / 反引号片段照常检查。

## 9. 范围变更 / 依赖变更
- tester 第 1 轮：A2 写「blocked 或 waiting_human … 转为 ready」。waiting_human 保留现有接续（卡转 in_progress + RESUME，由 gate-sync / 调度器接续），因为 test_answers / test_telegram / test_serve_answer 有多条断言依赖它；只有 blocked 转 ready。若要 waiting_human 也转 ready，需改这些断言，请用户确认。
- builder：采纳决定（S-003-adjustments 第 2 项）：waiting_human 保留 in_progress + RESUME 接续，但同时把主仓库 backlog 行（waiting_human / blocked / claimed）改为 in_progress，卡与 backlog 两份一致。
- builder：gate_github.py（已在 allowed_paths）发布 hook 与 gate-sync 对缺 paths 的 unlock 门卡给出同一提示；harness-loop.sh 本轮卡住 / 等人的任务转回 ready 后从 SKIP 移出，由 pick-batch 重新派发。
- tester 第 1 轮：unlock 门卡没有 paths 就不快照（S-003#8）。现有 `pkg/tests/test_answers.sh` 的 G-T101-13（unlock，任务卡无 unlock:）加了夹具行 `paths: [scripts/**]`，断言不变。

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 契约 ①–⑤ 按接口约定逐条实现即可：own_task_paths 让规则 4 / control-diff / strict 放行本任务文件；unlock 快照取门卡 paths:，缺则不快照；settle 对 blocked 任务转 ready | harness_lib（own_task_paths、_gate_unlock_paths、unlock_paths_missing、settle_answer、control_diff、strict_settings、CLI answer/show）、protect_paths、guard_bash（file_heredocs、answer_in_gate_doc）、两个 SKILL | test_lifecycle 101/101，其余全绿 |
| 2 | waiting_human 接续只改卡不改 backlog，两份会不一致（S-003-adjustments 第 2 项） | settle_answer：waiting_human → 卡 in_progress + .resume，同时主仓库 backlog 行（waiting_human/blocked/claimed）→ in_progress | test_answers / test_telegram / test_serve_answer 仍全绿 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
