---
id: T-013
title: doctor / down / 定时任务到期
status: proposed
priority: P2
risk: low
size: S
source: human
spec: S-002
test_owner: tester
branch: task/T-013-doctor
worktree: .claude/worktrees/T-013
session: auto
depends_on: [T-008]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/cli/doctor_cmd.py, pkg/bin/harness, pkg/scripts/gate-sync.sh, pkg/scripts/harness-loop.sh, pkg/tests/test_doctor.sh, pkg/tests/run.sh, pkg/tests/fake/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-013 doctor / down / 定时任务到期

## 1. 背景与目标
随时看得到 harness 在你电脑上跑着什么，并能一键停掉；定时任务不会在项目结束后永远跑下去。

## 2. 范围
**做：**
- `harness doctor`：定时任务（含到期日）、存活的调度器与 bot（pid 目录）、旧 worktree、久未答的门卡、沙箱依赖
- `harness down`：停进程、移除定时任务，幂等
- install-cron 写 `# harness expires=<日期>`，每次运行先检查到期

**不做（明确排除）：**
- 不删除 worktree（只列出）

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 什么算在跑 | `$XDG_STATE_HOME/harness/run/*.pid` 里存活的进程 | 挑错 F#8 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | 新命令；gate-sync install-cron；调度器写 pid | gate-sync.sh:18-24 |
| 风险 | low | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester：假 crontab + HARNESS_NOW 测到期；down 两次无害 — 结果：
- [ ] 2. 实现 — 结果：
- [ ] 3. 完整验证 — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. doctor 输出五类信息（S-002#16） — 证据：
- [ ] A2. down 停掉 pid 进程、移除定时任务，第二次执行退出码 0（S-002#16） — 证据：
- [ ] A3. HARNESS_NOW 超过到期日时定时任务移除自己，晨报与 doctor 提示（S-002#17） — 证据：
- [ ] A4. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A5. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- （无）

## 6. Guardrails（本任务特有）
- 只动带 harness 标记的定时任务

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
