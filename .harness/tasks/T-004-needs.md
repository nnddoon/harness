---
id: T-004
title: 需求页：每句需求的状态与证据
status: ready
priority: P1
risk: medium
size: M
source: human
spec: S-001
test_owner: tester          # tester = 测试只由 tester 子代理写（默认）| any = 小修可自己改测试（需在对齐时说明）
branch: task/T-004-needs
worktree: .claude/worktrees/T-004
session: auto               # auto = 由调度规则决定（harness_lib.py decide）| same | new = 人工强制
depends_on: [T-002]
context_files: [docs/specs/S-001-harness-v01.md]
allowed_paths: [pkg/cli/serve_cmd.py, pkg/.claude/skills/spec/**, pkg/.harness/tasks/_TEMPLATE.md, pkg/tests/test_serve_needs.sh]
locked_paths: []            # 本任务额外禁止修改的 glob（全局 locks.txt 之外）
unlock: []                  # 需要临时解锁的路径（必须有对应 approved 的 unlock 人工门）
gates: []                   # 关联人工门，例如 [G-T013-1]
auto_ok: no                 # yes = 低风险可自动批准进入 ready（仅 groom 提议使用）
---

# T-004 需求页：每句需求的状态与证据

## 1. 背景与目标
看板需求页目前只列任务。做完后：spec 的每条验收对应到任务卡验收项，显示做好/在做/等你，点开看影响范围、测试、尝试日志。

## 2. 范围
**做：**
- 

**不做（明确排除）：**
- 

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
|  |  |  |

**影响分析**（impact-analyst 子代理产出；allowed_paths / locked_paths / guardrails 由它推出）
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 |  |  |
| 调用方 / 依赖方 |  |  |
| 受影响的测试 |  |  |
| 对外契约（API、事件、schema、配置、URL） |  |  |
| 数据 / 迁移 |  |  |
| 依赖变更 |  |  |
| 风险等级与理由 |  |  |

## 4. 修改过程（计划 → 执行日志）
> 执行时每完成一步：勾选，并在「结果」写一行证据（提交号、命令输出摘要）。计划变更时不删旧步骤，划掉并写原因。

- [ ] 1. <步骤> — 结果：
- [ ] 2. <步骤> — 结果：
- [ ] 3. 补/改测试 — 结果：
- [ ] 4. 完整验证 — 结果：

## 5. 验收标准
**A. 机器可验证（每项附证据）**
- [ ] A1 spec 验收条目带编号，任务卡验收项可引用（例如 S-001#3）
- [ ] A2 需求页按条目显示状态与证据
- [ ] A3 `pkg/tests/run.sh` 全过

**B. 需要人确认**
- （无）

## 6. Guardrails（本任务特有）
- 不改：<例如 播放器对外事件名 `onRateChange` 的签名（T-010 已交付给统计模块）>
- 不引入：<例如 新的 UI 库>
- 兼容：<例如 保持 iOS Safari 15 可用>

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
