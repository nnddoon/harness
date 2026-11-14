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
depends_on: [T-018]
context_files: [docs/specs/S-003-field-fixes.md, docs/feedback/s002-field-test.md]
allowed_paths: [pkg/.claude/hooks/harness_lib.py, pkg/.claude/hooks/protect_paths.py, pkg/.claude/hooks/gate_github.py, pkg/.claude/hooks/guard_bash.py, pkg/.claude/skills/task-align/SKILL.md, pkg/.claude/skills/human-gate/SKILL.md, pkg/scripts/harness-loop.sh, pkg/tests/test_lifecycle.sh, pkg/scripts/test-harness.sh, plugins/harness/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-021 任务不自锁、解锁后接续

## 1. 背景与目标
任务因 locked_paths 含 .harness/** 被自己锁死（F-9）；解锁门卡批准后任务不接续（F-12）；guard_bash 把 heredoc 新建门卡误判成写答案。

## 2. 范围
**做：**
- task-align 不把 .harness/** 写进 locked_paths；protect_paths / control-diff / T-018 的 denyWrite 永远放行本任务自己的卡、交接包、门卡
- unlock 门卡快照必须带 paths，否则拒绝快照并提示
- 记录 unlock 批准后按快照任务把 blocked 转 ready 并排接续；调度器重新派发已批准解锁的 blocked 任务
- guard_bash：新建门卡文件（无 answer 内容）不再被当作写答案

**不做（明确排除）：**
- 不放宽答案库只由控制面写的规则

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
- [ ] 1. tester 写失败测试 — 结果：
- [ ] 2. 实现 — 结果：
- [ ] 3. 挑错 — 结果：
- [ ] 4. verifier — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. task-align 生成的卡 locked_paths 不含 .harness/**；任务能写自己的卡、交接包、门卡（S-003#6） — 证据：
- [ ] A2. 无 paths 的 unlock 门卡不被快照且有提示；有 paths 的批准后任务转 ready 并被调度器派发（S-003#8） — 证据：
- [ ] A3. heredoc 新建门卡不被 guard_bash 拒绝，写 answer 仍被拒 — 证据：
- [ ] A4. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A5. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- [ ] B1. 在你的 Mac 上：一个小任务从对齐到开 PR、合并门卡全流程跑通 — 门卡：

## 6. Guardrails（本任务特有）
- 答案仍只认答案库

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- 

## 9. 范围变更 / 依赖变更
- 

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
