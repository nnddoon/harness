---
id: T-000
title: <一句话标题>
status: proposed            # proposed | ready | claimed | in_progress | waiting_human | blocked | review | done
priority: P2                # P0 紧急 | P1 本轮必须 | P2 应该 | P3 有空再做
risk: low                   # low | medium | high（high 必须 security-auditor + 人工门）
size: S                     # S(<1h) | M(半天) | L(1天+，考虑拆分)
source: human               # human | groom（审核对话提议）| github#n
spec:                       # 所属 spec，例如 S-002（大需求才有）
test_owner: tester          # tester = 测试只由 tester 子代理写（默认）| any = 小修可自己改测试（需在对齐时说明）
branch: task/T-000-slug
worktree: .claude/worktrees/T-000
session: auto               # auto = 由调度规则决定（harness_lib.py decide）| same | new = 人工强制
depends_on: []              # 例如 [T-010]
context_files: []           # 必读文件，例如 [.harness/handoffs/T-010.md, docs/api.md]
allowed_paths: []           # 允许修改的 glob，例如 [apps/web/src/player/**, apps/web/tests/player/**]
locked_paths: []            # 本任务额外禁止修改的 glob（全局 locks.txt 之外）
unlock: []                  # 需要临时解锁的路径（必须有对应 approved 的 unlock 人工门）
gates: []                   # 关联人工门，例如 [G-T013-1]
auto_ok: no                 # yes = 低风险可自动批准进入 ready（仅 groom 提议使用）
---

# T-000 <标题>

## 1. 背景与目标
<为什么做；做完后用户/系统能做到什么。1–3 句。>

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
<!-- 属于某个 spec 时，在验收项后面写上它证明的是 spec 的哪一条，例如「- [ ] A1 刷新后保留倍速（S-xxx#2）」，看板「需求」页会据此显示每句需求的状态与证据。 -->
> 每条都必须能被验证：写明「怎么验证」。机器可验证的放 A，需要人判断的放 B（会生成人工门）。

**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. <行为描述> — 验证：`<命令>` 退出码 0 / 输出包含 `<关键字>` — 证据：
- [ ] A2. 已有测试全部通过，未删除/跳过任何测试 — 验证：`<测试命令>` — 证据：
- [ ] A3. Lint/类型检查通过 — 验证：`<命令>` — 证据：
- [ ] A4. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only origin/main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- [ ] B1. <例如：倍速选择器在手机上好点、好看> — 门卡：G-Txxx-n

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
<!-- 挑错角度：python3 .harness/lib/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
