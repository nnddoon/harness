---
id: T-004
title: 需求页：每句需求的状态与证据
status: review
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
- [x] 1. tester：先写 test_serve_needs.sh（13 项），1/13（红）
- [x] 2. builder：serve_cmd.py 需求页按 spec 编号条目汇总状态、证据、来龙去脉（details，不用 JS）；spec skill 与任务卡模板写明引用写法
- [x] 3. 第一次打补丁的脚本引号冲突，没有写入；改用文件脚本
- [x] 4. 挑错（3 个角度，本对话内）：无成立问题
- [x] 5. 顺手修 dogfood 两条（先补 2 个测试，红→绿），登记第 9 节
- [x] 6. 验收与范围检查

## 5. 验收标准
**A. 机器可验证（每项附证据）**
- [x] A1 spec 验收条目带编号，任务卡验收项可引用（例如 S-001#3） — 证据：spec skill 第 3、4 步写明编号即 id（S-xxx#n）与验收项引用写法；任务卡模板第 5 节有示例；测试「spec skill tells you to number acceptance」「task template shows how to reference a requirement」通过
- [x] A2 需求页按条目显示状态与证据 — 证据：「summary counts per requirement：4 句需求 · 1 做好了 · 1 等你看 · 1 等你 · 1 还没有任务」「#1 done with its evidence」「#2 waiting for your review」「#3 waiting for you」「#4 has no task yet」「details: impact / attempts / adversarial」「details open without JavaScript」通过
- [x] A3 `pkg/tests/run.sh` 全过 — 证据：`bash pkg/tests/run.sh` → test_serve_needs 15/15，其余 34/19/20/49 全过；`bash pkg/scripts/test-harness.sh` 201/201

**B. 需要人确认**
- （无）

## 6. Guardrails（本任务特有）
- 不改：<例如 播放器对外事件名 `onRateChange` 的签名（T-010 已交付给统计模块）>
- 不引入：<例如 新的 UI 库>
- 兼容：<例如 保持 iOS Safari 15 可用>

## 7. 当前进展（中断/换对话时更新）
- 2026-11-12 完成，进入 review。分支 task/T-004-needs（基于 integration/20261112-b）。

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- 

## 9. 范围变更 / 依赖变更
- 2026-11-12 顺手修了 docs/feedback/dogfood.md 里的两条（都在本任务的 serve_cmd.py 内、先写测试）：手机宽度下任务号和标签不再折行；「决定」页按真实状态说「几件在跑、几件排队」，不再一律写「其余的都在跑」。
- 从 integration/20261112-b 开工（依赖 T-003 对 serve_cmd.py 的改动）。

## 10. Verifier 结论
- 结论：PASS
- 说明：A1–A3 全过；只改了 allowed_paths 内的文件；范围扩展已登记第 9 节。

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 一次性打补丁 | python heredoc | 引号冲突导致语法错误，未写入任何文件 |
| 2 | 补丁写成文件再执行 | /tmp/fix_t004.py | 13/13 |
| 3 | 修「都在跑」文案 | running_line() | 先红后绿，15/15 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
| 1 | 3 | 0 | 0 | 3 个角度在本对话内做（不是独立会话）：子标题 ### 不会误判为验收节；模板里的示例在 HTML 注释中，不会被算成验收项或需求引用；T-003 交接包要求保留的写入保护均未改动。无成立问题 |
