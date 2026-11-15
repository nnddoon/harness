---
id: T-024
title: 0.2.2：控制面按基准任务卡检查改动范围
status: claimed
priority: P0
risk: high
size: M
source: human
spec: S-003
test_owner: tester
branch: task/T-024-scope-check
worktree: .claude/worktrees/T-024
session: auto
depends_on: [T-023]
context_files: [docs/feedback/s003-review-r1.md, docs/feedback/best-practices-review.md]
allowed_paths: [pkg/.claude/hooks/harness_lib.py, pkg/.claude/hooks/protect_paths.py, pkg/.claude/hooks/gate_github.py, pkg/scripts/harness-loop.sh, pkg/cli/doctor_cmd.py, pkg/tests/test_scope.sh, pkg/tests/test_control_paths.sh, pkg/tests/test_lifecycle.sh, pkg/scripts/test-harness.sh, pkg/plugin/RELEASED.json, pkg/README.md, plugins/harness/**, docs/feedback/best-practices-review.md]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-024 0.2.2：控制面按基准任务卡检查改动范围

## 1. 背景与目标
外部审查（`docs/feedback/best-practices-review.md` 三-1、三-2）指出：R-1 的根源是「列举输入」，T-023 的配置文件清单会一直补不完；更大的洞是 `allowed_paths` 只由会话内的编辑 hook（protect_paths 规则 5）检查——Bash 写文件不受管，而且任务自己可以改任务卡的 `allowed_paths`（§9 写一句就扩大范围），等于执行者给自己定范围。用户决定把「按基准任务卡检查改动范围」放进 0.2.2（2026-11-15，选 A）。

目标：任务分支改动的每个文件都必须落在**基准提交（main）上那张任务卡**的 `allowed_paths` 内（加上任务自己的记录文件）；范围外的改动由控制面拦下，走现有 ctl 门卡流程，人批准后才可合并。分支里对自己任务卡范围字段的修改一律不算数。T-023 的 JS 配置清单保留，作为 strict denyWrite 的早期提醒。

## 2. 范围
**做：**
- `control_diff(..., task=...)`：任务卡在基准提交里有非空 `allowed_paths` 时，分支 diff 里不匹配它、也不是 `own_task_paths(task)` 的文件 → 计入命中（与 CONTROL_PATHS 命中同一出口，所以 harness-loop finish、gate_github 发布 / 合并检查自动覆盖）。范围只取基准提交的卡（不取分支卡；人在 main 上改卡并提交即为扩大范围）。
- 已批准的 ctl 门卡：快照里列出的范围外文件，在同一提交内容下放行（与 `approved_unlock_paths` 同一机制；文件之后再改则重新命中）。
- 基准卡没有 `allowed_paths` 或为空 → 不做范围检查（退回现有列举），doctor 对 ready/claimed/in_progress 的这类任务给一行提醒。
- protect_paths 规则 5：`allowed_paths` 以主仓库任务卡为准（取不到时才用 worktree 卡）；worktree 里修改本任务卡 frontmatter 的 `allowed_paths` / `locked_paths` / `unlock` / `auto_ok` / `risk` 一律拒绝，提示在 §9 写提议并开门卡。
- ctl 门卡正文区分「控制文件」与「超出任务范围」两类命中，范围外的列出文件并说明批准的含义。
- 版本仍为 0.2.2（未发布），重建插件与 RELEASED.json；README 0.2.2 一节加一行。

**不做（明确排除）：**
- 不做「测试数不能变少」的不变量（→ S-004）。
- 不做风险下限按路径计算（→ S-004），只是禁止任务自己改 risk。
- 不改 Python / JS 入口列举逻辑。

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 放进 0.2.2 还是 S-004 | 0.2.2，单开 T-024 | 用户 2026-11-15 选 A |
| 范围以哪张卡为准 | 基准提交（main）上的卡 | 推断（执行者不给自己定范围） |
| 扩大范围怎么批 | ctl 门卡（现有流程）或人在 main 上改卡 | 推断 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | control_diff、protect_paths 规则 5、ctl 门卡正文、doctor | `harness_lib.py` control_diff；`protect_paths.py` 规则 5 |
| 调用方 | harness-loop finish（ctl_block）、gate_github 发布与合并检查 | `harness-loop.sh` ctl_block / control-diff；`gate_github.py` control_diff |
| 风险 | high（控制面；误拦会卡住所有任务，漏拦即范围失效） | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester — 结果：
- [ ] 2. 实现 — 结果：
- [ ] 3. 挑错 — 结果：
- [ ] 4. verifier — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 分支改了基准卡 `allowed_paths` 外的文件（经 Edit 或 Bash 均可）→ control_diff 命中，finish 走 ctl 门卡、不合并 — 证据：
- [ ] A2. 分支自己扩大任务卡 `allowed_paths` 不起作用；人在 main 上扩大并提交后不再命中 — 证据：
- [ ] A3. 批准的 ctl 门卡放行快照内的范围外文件；文件再改后重新命中；被拒则保持拦下 — 证据：
- [ ] A4. R-1 复现（只改 `jest.config.js`，卡的 allowed_paths 为 `src/**`）在没有 JS 清单的情况下也被范围检查拦下 — 证据：
- [ ] A5. protect_paths 以主仓库卡为准，worktree 里改范围字段被拒 — 证据：
- [ ] A6. 无 allowed_paths 的卡不做范围检查，doctor 提醒 — 证据：
- [ ] A7. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A8. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only task/T-023-js-runner-configs...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- （无）

## 6. Guardrails（本任务特有）
- 范围只信基准提交；分支和 worktree 里的卡只当数据。
- 任务自己的记录文件（own_task_paths）永远放行，但 ctl 门卡及其附件除外（沿用 is_own_path）。
- 拦下时信息要能直接用：列出文件、说明怎么批。

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）

## 9. 范围变更 / 依赖变更

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
