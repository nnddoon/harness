---
id: T-017
title: 文档、教程与打包
status: ready
priority: P3
risk: low
size: S
source: human
spec: S-002
test_owner: tester
branch: task/T-017-docs-packaging
worktree: .claude/worktrees/T-017
session: auto
depends_on: [T-011, T-015, T-016]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/README.md, pkg/.claude/rules/**, pkg/plugin/**, pkg/tests/test_plugin.sh, plugins/harness/**, docs/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-017 文档、教程与打包

## 1. 背景与目标
新的 strict 模式、doctor、收件箱写进 README、规则和教程，插件打包带上新命令。

## 2. 范围
**做：**
- README、规则、教程更新
- build.sh 打包新命令与 hook，重新发布 plugins/harness
- test_plugin 断言新命令存在

**不做（明确排除）：**
- 不改功能代码

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 教程放哪里 | 现有教程文档追加一节 | - |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | 文档与打包 | pkg/plugin/build.sh |
| 风险 | low | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester：test_plugin 新断言 — 结果：
- [ ] 2. 更新文档与打包 — 结果：
- [ ] 3. 完整验证 — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 插件构建产物含 launch、doctor、inbox 与新 hook，test_plugin 通过（S-002#20） — 证据：
- [ ] A2. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A3. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- （无）

## 6. Guardrails（本任务特有）
- 不改功能代码

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
