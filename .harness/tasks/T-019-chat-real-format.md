---
id: T-019
title: 对话选项卡按真机格式记录
status: ready
priority: P0
risk: medium
size: S
source: human
spec: S-003
test_owner: tester
branch: task/T-019-chat-real-format
worktree: .claude/worktrees/T-019
session: auto
depends_on: []
context_files: [docs/specs/S-003-field-fixes.md, docs/feedback/s002-field-test.md]
allowed_paths: [pkg/.claude/hooks/chat_answer.py, pkg/.claude/settings.json, pkg/plugin/build.sh, pkg/tests/test_chat_answer.sh, plugins/harness/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-019 对话选项卡按真机格式记录

## 1. 背景与目标
真机上 Claude Code 把用户答案写回 PostToolUse 的 tool_input.answers，原实现把它当成预填一律拒收（F-5）。改为在 PreToolUse 判定预填。

## 2. 范围
**做：**
- PreToolUse(AskUserQuestion)：tool_input 带 answers 即拒绝这次调用（permissionDecision deny + 原因）
- PostToolUse：从 tool_input.answers（问题 → label）或 tool_response 读取答案并按快照严格匹配记录
- Other 自由输入不记录并说明原因；有后果的 A 给正确理由

**不做（明确排除）：**
- 不放宽快照逐字匹配

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 真机字段 | PreToolUse tool_input 只有 questions；PostToolUse 有 answers,questions（有时 annotations） | 现场报告第 2 节 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | chat_answer.py 与 hook 注册 | - |
| 风险 | medium | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester 用真机字段结构写失败测试 — 结果：
- [ ] 2. 实现 — 结果：
- [ ] 3. 挑错 — 结果：
- [ ] 4. verifier — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 真机格式 PostToolUse（answers 在 tool_input）选 B → 记录 via 对话（S-003#4） — 证据：
- [ ] A2. PreToolUse 带预填 answers → 拒绝调用且不记录（S-003#4） — 证据：
- [ ] A3. Other 输入不记录且 systemMessage 说明；有后果的 A 提示去终端 / 看板 / Telegram（S-003#4） — 证据：
- [ ] A4. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A5. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- [ ] B1. 在你的 Mac 上：ui 卡选 B 记录；design 卡选 A 被拒且理由正确 — 门卡：

## 6. Guardrails（本任务特有）
- 字段缺失时不记录、不报错

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
