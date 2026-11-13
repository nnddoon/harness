---
id: T-012
title: 审计日志与审计页
status: proposed
priority: P2
risk: medium
size: S
source: human
spec: S-002
test_owner: tester
branch: task/T-012-audit
worktree: .claude/worktrees/T-012
session: auto
depends_on: [T-008, T-010]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/.claude/hooks/audit_log.py, pkg/.claude/hooks/harness_lib.py, pkg/.claude/settings.json, pkg/cli/serve_cmd.py, pkg/plugin/build.sh, pkg/tests/test_audit.sh, pkg/tests/run.sh]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-012 审计日志与审计页

## 1. 背景与目标
每次工具调用、护栏判定、门卡答复都留在仓库外的审计日志里，敏感值打码；看板带令牌时可按任务查看。

## 2. 范围
**做：**
- PostToolUse（全部工具）与护栏判定写 `$XDG_STATE_HOME/harness/<仓库>/audit/<日期>.jsonl`
- 打码规则见 S-002#15，含控制面配置里的 token 原文
- 看板「审计」页：按任务、按天，只在带令牌时显示

**不做（明确排除）：**
- 不上传任何日志
- 不记录文件全文，只记路径和截断后的命令

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 日志放哪里 | 仓库外，不进 git | spec §4 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | 新增 hook；settings 与插件 hooks.json 加一项；看板新增一页 | pkg/.claude/settings.json；pkg/plugin/build.sh |
| 风险 | medium：日志可能含敏感内容 | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester：打码规则逐条夹具测试；未带令牌访问审计页 403 — 结果：
- [ ] 2. 实现 hook 与页面 — 结果：
- [ ] 3. 完整验证 + 对抗审查 — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 每次工具调用一行 JSON，含时间、会话、任务、工具、截断输入、判定（S-002#15） — 证据：
- [ ] A2. 打码夹具全部通过，含控制面 token 原文（S-002#15） — 证据：
- [ ] A3. 无令牌访问审计页返回 403（S-002#15） — 证据：
- [ ] A4. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A5. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- （无）

## 6. Guardrails（本任务特有）
- 日志写入失败不阻塞工具调用
- 单行不超过 4 KB

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
