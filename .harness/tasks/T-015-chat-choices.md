---
id: T-015
title: 对话内选项卡
status: ready
priority: P2
risk: medium
size: S
source: human
spec: S-002
test_owner: tester
branch: task/T-015-chat-choices
worktree: .claude/worktrees/T-015
session: auto
depends_on: [T-010]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/.claude/hooks/chat_answer.py, pkg/.claude/settings.json, pkg/.claude/skills/human-gate/SKILL.md, pkg/plugin/build.sh, pkg/tests/test_chat_answer.sh, pkg/tests/run.sh]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-015 对话内选项卡

## 1. 背景与目标
你在对话里时，门卡直接弹成选项；你点的答案由 hook 写进答案库，不经 Claude 之手。

## 2. 范围
**做：**
- PostToolUse(AskUserQuestion) hook：从工具结果取答案写库（问题标题以门卡号开头）
- UserPromptSubmit hook：消息恰好是 `G-x-n: L`（可带备注）时写库
- 无人值守或非交互会话时两个 hook 都不生效

**不做（明确排除）：**
- 不解析其他格式的消息

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 为什么限制格式 | 接续提示里可能夹带伪造答复 | 挑错 S#7 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | 新 hook，settings 与插件 hooks.json | - |
| 风险 | medium | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester：用标准输入喂 UserPromptSubmit 与 PostToolUse 的 JSON；HARNESS_UNATTENDED=1 时不写 — 结果：
- [ ] 2. 实现 — 结果：
- [ ] 3. 完整验证 + 对抗审查 — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. `G-x-n: B 备注` 写库，via 对话（S-002#13） — 证据：
- [ ] A2. HARNESS_UNATTENDED=1 时两个 hook 都不写（S-002#13） — 证据：
- [ ] A3. AskUserQuestion 结果写库，问题未以门卡号开头时忽略（S-002#13） — 证据：
- [ ] A4. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A5. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- [ ] B1. 在你的 Claude Code 里：开一张门卡，选项卡出现，点选后看板显示已答（S-002#13 人工） — 门卡：

## 6. Guardrails（本任务特有）
- hook 字段以当前 Claude Code 版本为准，字段缺失时不写、不报错

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
