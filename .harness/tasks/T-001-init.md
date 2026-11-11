---
id: T-001
title: harness init：识别技术栈并生成配置
status: review
priority: P1
risk: low
size: S
source: human
spec: S-001
test_owner: tester          # tester = 测试只由 tester 子代理写（默认）| any = 小修可自己改测试（需在对齐时说明）
branch: task/T-001-init
worktree: .claude/worktrees/T-001
session: auto               # auto = 由调度规则决定（harness_lib.py decide）| same | new = 人工强制
depends_on: []
context_files: [docs/specs/S-001-harness-v01.md]
allowed_paths: [pkg/bin/**, pkg/cli/__init__.py, pkg/cli/init_cmd.py, pkg/tests/test_init.sh, pkg/tests/fixtures/**]
locked_paths: []            # 本任务额外禁止修改的 glob（全局 locks.txt 之外）
unlock: []                  # 需要临时解锁的路径（必须有对应 approved 的 unlock 人工门）
gates: []                   # 关联人工门，例如 [G-T013-1]
auto_ok: no                 # yes = 低风险可自动批准进入 ready（仅 groom 提议使用）
---

# T-001 harness init：识别技术栈并生成配置

## 1. 背景与目标
新仓库接入要手填 verify.sh、quick-check.sh、allow-commands.txt，这是最大的上手门槛。做完后：`harness init` 读仓库、识别 Python/Node，生成配置并合并 .gitignore/.gitattributes，你只确认。

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
- [x] 1. tester：先写 pkg/tests/test_init.sh（34 项），跑出 5/34（红，只有拒绝类用例通过）
- [x] 2. builder：pkg/bin/harness 分发器 + pkg/cli/init_cmd.py（识别、安装、生成配置、追加 .gitignore/.gitattributes）
- [x] 3. 修第 1 次失败：ruff/mypy 扫到了 harness 自己装的文件
- [x] 4. 挑错：在 init 出来的仓库里跑 harness 自测 196/196
- [x] 5. 验收与范围检查

## 5. 验收标准
**A. 机器可验证（每项附证据）**
- [x] A1 Python 示例仓库（pyproject + tests/）跑 `harness init --yes`：生成的 verify.sh 含 pytest，quick-check.sh 对 .py 生效，allow-commands.txt 含 pytest — 证据：`bash pkg/tests/test_init.sh` → py 段 19 项全过（verify.sh 含 pytest/ruff/mypy 且在示例仓库 exit 0；quick-check 对 .py 生效；allow 含 ^pytest）
- [x] A2 Node 示例仓库（package.json scripts: test/lint）：verify.sh 用 `npm run test` 和 `npm run lint`；有 pnpm-lock.yaml 时用 pnpm — 证据：同上 node 段 7 项全过（pnpm run test/lint/typecheck，verify exit 0）；npm 段 1 项过
- [x] A3 已有 CLAUDE.md 和 .claude/settings.json 不被覆盖，改写成 CLAUDE.harness.md / settings.harness.json 并提示合并 — 证据：py 段：CLAUDE.md 首行仍是「# mine」，CLAUDE.harness.md 与 .claude/settings.harness.json 已写，输出提示合并
- [x] A4 重跑不重复追加 .gitignore / .gitattributes 行，不覆盖已配置过的 verify.sh — 证据：py 段：追加「我自己加的」后重跑仍在；.gitignore / .gitattributes 行各 1 次
- [x] A5 `pkg/tests/run.sh` 全过 — 证据：`bash pkg/tests/run.sh` → test_init.sh: 34/34 passed

**B. 需要人确认**
- （无）

## 6. Guardrails（本任务特有）
- 不改：<例如 播放器对外事件名 `onRateChange` 的签名（T-010 已交付给统计模块）>
- 不引入：<例如 新的 UI 库>
- 兼容：<例如 保持 iOS Safari 15 可用>

## 7. 当前进展（中断/换对话时更新）
- 2026-11-12 完成，进入 review。分支 task/T-001-init。
- 下游 T-005（插件）依赖本任务：插件装好后调用同一个 init。

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- 

## 9. 范围变更 / 依赖变更
- 

## 10. Verifier 结论
- 结论：PASS
- 说明：A1–A5 全过（命令：bash pkg/tests/run.sh）；SCOPE 见范围检查；未删改既有测试；无新依赖（只用标准库）。

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 生成的 ruff check . / mypy . 在示例仓库能过 | 首版命令 | 失败：扫到 .claude/hooks、scripts/testdata 共 64 个 ruff 错 |
| 2 | 只检查用户自己的代码 | 加 --extend-exclude / --exclude 排除 harness 自带文件 | 通过 34/34 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
| 1 | 1 | 0 | 0 | 角度：测试测的是不是需求。在本对话内做（不是独立会话）：init 出来的仓库跑 harness 自测 196/196，未发现成立问题 |
