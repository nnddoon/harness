---
id: T-005
title: 打包成 Claude Code 插件
status: review
priority: P1
risk: medium
size: M
source: human
spec: S-001
test_owner: tester          # tester = 测试只由 tester 子代理写（默认）| any = 小修可自己改测试（需在对齐时说明）
branch: task/T-005-plugin
worktree: .claude/worktrees/T-005
session: auto               # auto = 由调度规则决定（harness_lib.py decide）| same | new = 人工强制
depends_on: [T-001]
context_files: [docs/specs/S-001-harness-v01.md]
allowed_paths: [pkg/.claude-plugin/**, pkg/plugin/**, pkg/tests/test_plugin.sh]
locked_paths: []            # 本任务额外禁止修改的 glob（全局 locks.txt 之外）
unlock: []                  # 需要临时解锁的路径（必须有对应 approved 的 unlock 人工门）
gates: []                   # 关联人工门，例如 [G-T013-1]
auto_ok: no                 # yes = 低风险可自动批准进入 ready（仅 groom 提议使用）
---

# T-005 打包成 Claude Code 插件

## 1. 背景与目标
其他仓库接入要拷文件。做完后：一行安装插件，再跑 harness init。

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
- [x] 1. tester：先写 test_plugin.sh（19 项），6/19（红）；修正一条会误判通过的用例（diff 出错时输出为空）
- [x] 2. builder：pkg/plugin/build.sh + VERSION：manifest、hooks.json（路径改成 ${CLAUDE_PLUGIN_ROOT}）、hooks、skills、agents、README
- [x] 3. 修第 1 次失败：settings.json 用的是 "$CLAUDE_PROJECT_DIR"/.claude/hooks/ 写法
- [x] 4. 挑错（3 个角度，本对话内）：权限 deny 不在插件里、与仓库 hooks 重复、scripts 仍依赖仓库 hooks → README 写明，后两条记第 8 节
- [x] 5. 验收与范围检查

## 5. 验收标准
**A. 机器可验证（每项附证据）**
- [x] A1 插件清单通过校验 — 证据：「claude plugin validate passes」（Claude Code 2.1.322）、「manifest in .claude-plugin/」「only plugin.json inside」「manifest version」通过
- [x] A2 新仓库装插件后 hooks 生效且不依赖仓库里的 .claude/hooks/ — 证据：在没有 .claude/hooks/ 的仓库里：「plugin guard blocks force push」「plugin path guard protects locked files」通过；「every hook command uses CLAUDE_PLUGIN_ROOT」「every script a hook calls is in the plugin」「no repo-relative hook paths left」通过
- [x] A3 `pkg/tests/run.sh` 全过 — 证据：`bash pkg/tests/run.sh` → test_plugin.sh 19/19（另 test_init 34/34、test_serve 20/20）

**B. 需要人确认**
- （无）

## 6. Guardrails（本任务特有）
- 不改：<例如 播放器对外事件名 `onRateChange` 的签名（T-010 已交付给统计模块）>
- 不引入：<例如 新的 UI 库>
- 兼容：<例如 保持 iOS Safari 15 可用>

## 7. 当前进展（中断/换对话时更新）
- 2026-11-12 完成，进入 review。分支 task/T-005-plugin。
- 本机试装：bash pkg/plugin/build.sh /tmp/harness-plugin && claude --plugin-dir /tmp/harness-plugin

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- 提议 T-007：插件模式下的 `harness init --plugin`——只装 .harness/ 和 scripts/，不装 .claude/hooks/，并写入权限 deny 列表；scripts/*.sh 与 stop_gate、permission_allow 的提示文字改为从插件目录找 harness_lib.py。
- 插件和仓库 hooks 同时存在时每个 hook 跑两次（门卡可能被发两次 Issue）。

## 9. 范围变更 / 依赖变更
- 

## 10. Verifier 结论
- 结论：PASS
- 说明：A1–A3 全过；只改了 allowed_paths 内的文件；构建可重复（两次产物 diff 为空）。

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | settings.json 里是 python3 .claude/hooks/x.py | 首版替换 | 失败：实际是 "$CLAUDE_PROJECT_DIR"/.claude/hooks/x.py，替换没生效 |
| 2 | 同时认这两种写法 | 改替换正则 | 通过 19/19 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
| 1 | 3 | 3 | 1 | 3 个角度在本对话内做（不是独立会话）：权限 deny 列表不在插件里（已在插件 README 说明）；插件与仓库 hooks 同时存在会跑两次；scripts 与两个 hook 的提示文字仍指向仓库路径 → 后两条超出范围，记第 8 节并提议 T-007 |
