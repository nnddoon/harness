---
id: T-022
title: 小问题与版本号 0.2.1
status: ready
priority: P1
risk: low
size: S
source: human
spec: S-003
test_owner: tester
branch: task/T-022-small-fixes
worktree: .claude/worktrees/T-022
session: auto
depends_on: [T-018, T-019, T-020, T-021]
context_files: [docs/specs/S-003-field-fixes.md, docs/feedback/s002-field-test.md]
allowed_paths: [pkg/plugin/**, pkg/.claude/hooks/harness_lib.py, pkg/.claude/hooks/audit_log.py, pkg/cli/**, pkg/tests/test_small_fixes.sh, pkg/tests/test_plugin.sh, pkg/README.md, plugins/harness/**, docs/specs/S-003-field-fixes.md]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-022 小问题与版本号 0.2.1

## 1. 背景与目标
把版本号升到 0.2.1 让已安装用户收到更新（F-1），并修 F-6、F-7、F-13、F-14、F-15 与 doctor/down 小问题。

## 2. 范围
**做：**
- VERSION 0.2.1；build.sh 写 plugin.json；测试：插件内容相对上次发布清单变化时版本必须变化
- show 比较快照时忽略控制面回写字段
- init 检测 npm 默认 exit 1 测试脚本并提示
- 审计打码 [?&]t=…
- 配对码错误 / 已用回一句提示
- Telegram 回调立即 answerCallbackQuery；记录后统一去掉已答消息按钮
- doctor 显示在跑的 serve；down 不留空 crontab
- README 记录 0.2.1 变化

**不做（明确排除）：**
- 不加新功能

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 版本策略 | 每次发布改 VERSION；测试防止忘记 | F-1 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | 打包与若干小处 | - |
| 风险 | low | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester — 结果：
- [ ] 2. 实现 — 结果：
- [ ] 3. 挑错 — 结果：
- [ ] 4. verifier — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. plugin.json version 为 0.2.1，版本检查测试通过（S-003#10） — 证据：
- [ ] A2. F-6/F-7/F-13/F-14/F-15 与 doctor/down 各有测试并通过（S-003#11） — 证据：
- [ ] A3. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A4. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- （无）

## 6. Guardrails（本任务特有）
- 不改行为以外的东西

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
