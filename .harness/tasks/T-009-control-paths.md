---
id: T-009
title: 控制路径守门与沙箱内验证
status: claimed
priority: P0
risk: high
size: M
source: human
spec: S-002
test_owner: tester
branch: task/T-009-control-paths
worktree: .claude/worktrees/T-009
session: auto
depends_on: [T-008]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/scripts/harness-loop.sh, pkg/scripts/new-task.sh, pkg/.claude/hooks/harness_lib.py, pkg/.claude/hooks/quick_check.py, pkg/cli/strict_profile.py, pkg/tests/test_control_paths.sh, pkg/tests/run.sh, pkg/tests/fake/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-009 控制路径守门与沙箱内验证

## 1. 背景与目标
控制面不再信任 agent 分支里的控制文件，也不再在沙箱外运行 agent 写的代码。改了控制路径的分支不能被合并、推送或当成下游基线；整合验证在沙箱里、无凭证地跑。

## 2. 范围
**做：**
- `harness_lib control-diff <base> <branch>`：命中控制路径且无已批准 unlock 时列出文件
- 调度器在整合、推送、作为下游基线之前调用它；命中则任务转 blocked 并开门卡
- 整合验证改用沙箱运行器（srt）执行，环境无凭证；srt 已获允许（D-007）；未安装时调度器拒绝在 strict 下整合并提示安装命令，不自动安装
- strict 模式下 quick_check hook 不执行项目命令，改为提示 Claude 在沙箱 Bash 里跑
- 沙箱 denyWrite 补上主仓库 `.git/hooks`、`.git/config`、`.git/info`

**不做（明确排除）：**
- 不实现推送和开 PR 的迁移（T-011）

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 为什么要 diff 检查 | git hash-object/update-index 可以不写文件路径就提交控制文件 | 挑错 S#3 |
| 验证为何要进沙箱 | verify.sh 运行 agent 写的测试，原来带着你的凭证在沙箱外跑 | 挑错 S#1 S#2，harness-loop.sh:96 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | integrate()、HARNESS_BASE 选择、quick_check.py | harness-loop.sh:77-110；quick_check.py:32-36 |
| 受影响测试 | 整合相关用例改用假 srt | pkg/scripts/test-harness.sh |
| 依赖变更 | 控制面可选使用 srt（你电脑上的工具，非项目依赖） | G-S002-1 |
| 风险 | high | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester：构造改了 .harness/verify.sh、.github/workflows、scripts/ 的分支（含用 git plumbing 提交的），断言调度器拒绝；假 verify.sh 打印环境，断言无凭证且经 srt 调用 — 结果：
- [ ] 2. 实现 control-diff 与调度器接入 — 结果：
- [ ] 3. 验证进沙箱、quick_check strict 分支 — 结果：
- [ ] 4. 完整验证 + 对抗审查 — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 改了控制路径（含 git plumbing 提交）的分支：不合并、不推送、不作为下游基线，任务 blocked 且有门卡（S-002#6） — 证据：
- [ ] A2. 改了 .github/** 的分支不推送（S-002#12） — 证据：
- [ ] A3. 整合验证经 srt 调用，验证进程环境无凭证（S-002#7） — 证据：
- [ ] A4. strict 模式下 quick_check hook 不执行任何项目命令（S-002#7） — 证据：
- [ ] A5. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A6. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- [ ] B1. 在你的电脑上：一个改了 .harness/verify.sh 的任务分支，夜间模式不合并并开出门卡（S-002#6 人工） — 门卡：

## 6. Guardrails（本任务特有）
- 有已批准 unlock 门卡的控制路径改动照常放行
- 不弱化现有整合失败重试逻辑

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
