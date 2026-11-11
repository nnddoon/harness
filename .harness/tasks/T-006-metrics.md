---
id: T-006
title: 三个指标自动计算
status: ready
priority: P1
risk: low
size: S
source: human
spec: S-001
test_owner: tester          # tester = 测试只由 tester 子代理写（默认）| any = 小修可自己改测试（需在对齐时说明）
branch: task/T-006-metrics
worktree: .claude/worktrees/T-006
session: auto               # auto = 由调度规则决定（harness_lib.py decide）| same | new = 人工强制
depends_on: []
context_files: [docs/specs/S-001-harness-v01.md]
allowed_paths: [pkg/.claude/hooks/harness_lib.py, pkg/scripts/test-harness.sh]
locked_paths: []            # 本任务额外禁止修改的 glob（全局 locks.txt 之外）
unlock: []                  # 需要临时解锁的路径（必须有对应 approved 的 unlock 人工门）
gates: []                   # 关联人工门，例如 [G-T013-1]
auto_ok: no                 # yes = 低风险可自动批准进入 ready（仅 groom 提议使用）
---

# T-006 三个指标自动计算

## 1. 背景与目标
两周自用要对比三个数字，不能靠手记。做完后：`harness_lib.py metrics` 输出三个数，晨报末尾加一行。

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
- [ ] A1 想法到合并：done 任务的卡片首次提交时间 → main 上提到该任务的首个提交时间，取中位数（小时）
- [ ] A2 每天打断：近 N 天新增门卡数（不含 decided_by: auto）/ N
- [ ] A3 手改配置：近 N 天非 harness 提交（主题不以 harness: 开头）中改动配置文件的次数
- [ ] A4 晨报末尾一行「本周：…」
- [ ] A5 `bash pkg/scripts/test-harness.sh` 全过

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
