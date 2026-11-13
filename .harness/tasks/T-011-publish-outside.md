---
id: T-011
title: 发布与推送移到控制面
status: proposed
priority: P1
risk: high
size: M
source: human
spec: S-002
test_owner: tester
branch: task/T-011-publish-outside
worktree: .claude/worktrees/T-011
session: auto
depends_on: [T-009, T-010]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/.claude/hooks/gate_github.py, pkg/.claude/hooks/harness_lib.py, pkg/scripts/harness-loop.sh, pkg/scripts/gate-sync.sh, pkg/.claude/skills/task-close/SKILL.md, pkg/.claude/settings.json, pkg/tests/test_publish.sh, pkg/tests/run.sh, pkg/tests/fake/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-011 发布与推送移到控制面

## 1. 背景与目标
strict 模式下 Claude 和它的 hooks 不做任何 GitHub 写操作；推分支、开 PR、开门卡 Issue、推素材由调度器或 gate-sync 在控制面完成。

## 2. 范围
**做：**
- goal_prompt 与 task-close：strict 时只写交接包和合并门卡草稿，不推不开 PR
- 调度器 finish()：控制路径检查通过后推分支、开 PR、把 PR 号写入答案库
- 门卡 Issue 发布与素材推送从 PostToolUse hook 移到 gate-sync；standard 模式保留旧行为

**不做（明确排除）：**
- 不改 standard 模式下的交互流程

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| hook 为什么也不行 | hook 在沙箱外、继承环境，可用 git 凭证助手 | 挑错 F#2 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | goal_prompt、task-close 第 4 步、finish()、整合 PR、publish/push_assets | harness_lib.py:160-166；task-close/SKILL.md:25；harness-loop.sh:215-226；gate_github.py:133-198 |
| 受影响测试 | gate 发布相关用例 | pkg/tests |
| 风险 | high | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester：假 gh / 假远端记录写调用，strict 下 Claude 侧为 0、调度器侧完成推送与 PR — 结果：
- [ ] 2. 改 goal 与 task-close — 结果：
- [ ] 3. 调度器与 gate-sync 接管发布 — 结果：
- [ ] 4. 完整验证 + 对抗审查 — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. strict 模式一次完整任务：Claude 及 hooks 对假 gh/假远端写调用 0 次；调度器推分支、开 PR、开门卡 Issue 各 1 次（S-002#11） — 证据：
- [ ] A2. standard 模式行为与现在一致（现有测试通过） — 证据：
- [ ] A3. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A4. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- （无）

## 6. Guardrails（本任务特有）
- 不改 decisions.md 格式
- 不在 standard 模式下改变用户可见流程

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
