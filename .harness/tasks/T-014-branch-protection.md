---
id: T-014
title: 分支保护向导
status: claimed
priority: P2
risk: medium
size: S
source: human
spec: S-002
test_owner: tester
branch: task/T-014-branch-protection
worktree: .claude/worktrees/T-014
session: auto
depends_on: [T-009]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/cli/init_cmd.py, pkg/plugin/skills/setup/SKILL.md, pkg/tests/test_init.sh, pkg/tests/fake/**]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-014 分支保护向导

## 1. 背景与目标
能在 GitHub 服务器端挡住合并的，就请你一键开上；开不了的说清楚原因。

## 2. 范围
**做：**
- setup 检查仓库可见性与计划（假 gh 可返回升级 Pro 的 403）
- 能开：开 external 门卡，内容为 main 必须走 PR、禁止强推，以及 Actions workflow 权限只读
- 不能开：一句话说明，并说明 strict 模式已在本机挡住

**不做（明确排除）：**
- 不在没有你批准时调用任何改设置的 API

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 私有仓库 | GitHub Free 的私有仓库没有分支保护，需要 Pro/Team | GitHub 文档 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | init_cmd 与 setup skill | pkg/cli/init_cmd.py |
| 风险 | medium：改 GitHub 设置属于对外操作，必须走门卡 | - |

## 4. 修改过程（计划 → 执行日志）
- [ ] 1. tester：假 gh 三种情形（公开、私有+Pro、私有+Free） — 结果：
- [ ] 2. 实现 — 结果：
- [ ] 3. 完整验证 + 对抗审查 — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 三种情形输出正确，未批准时 0 次写调用（S-002#18） — 证据：
- [ ] A2. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A3. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- [ ] B1. 在你的仓库上：批准门卡后分支保护生效（S-002#18 人工） — 门卡：

## 6. Guardrails（本任务特有）
- 这是 external 类门卡，永远问你

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
