---
id: T-017
title: 文档、教程与打包
status: in_progress
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
allowed_paths: [pkg/README.md, pkg/.claude/rules/**, pkg/.claude/skills/human-gate/SKILL.md, pkg/plugin/**, pkg/tests/test_plugin.sh, plugins/harness/**, docs/**, pkg/bin/harness, pkg/scripts/gates.sh]
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

## 接口约定（tester 写，builder 照此做；测试：pkg/tests/test_plugin.sh 中 `T-017` 开头的断言）
**打包（`bash pkg/plugin/build.sh <dir>`）**
- 产物含 `cli/launch_cmd.py`、`cli/doctor_cmd.py`、`cli/inbox_cmd.py`，`hooks/audit_log.py`、`hooks/chat_answer.py`。
- `hooks/hooks.json`：PreToolUse matcher `*` 与 PostToolUse matcher `*` 调 `${CLAUDE_PLUGIN_ROOT}/hooks/audit_log.py`；UserPromptSubmit（无 matcher）与 PostToolUse matcher `AskUserQuestion` 调 `.../chat_answer.py`。
- `bin/harness --help`：每个命令一行、行首缩进 + 命令名；含 `launch`、`doctor`、`down`（同一行写 `--prune-audit`）、`inbox`（同一行写 `setup`）。
- 改完重新发布：`bash pkg/plugin/build.sh plugins/harness`（test_plugin_install 检查它是最新的）。

**README（pkg/README.md，grep）** 必须出现：`strict`、`harness doctor`、`harness down`、`harness down --prune-audit`、`harness inbox setup`、`Telegram`、`srt`、`sandbox-runtime`、一条 `npm install -g …sandbox-runtime` 安装命令、终端答复命令 `answer G-xxx <字母>` 或 `answer <门卡号> …`；一行同时含 `standard`、`只靠护栏`、`边界`（S-002 §7 残余风险）。
不得再有主语为 Claude、不含「不」、且说「记进 `decisions.md`」/「关闭门卡」/「写 … `answer:`」的句子（按 。；切句）。

**human-gates.md**：`## 3.` 节（到下一个 `## ` 前）含「答复处理」，列出 终端、看板、GitHub、对话、Telegram 五个通道，含「控制面」，且有一行含 Claude + 不写/不改/从不 + `answer`。
**human-gate SKILL.md**：删去 `PostToolUse hook 会自动把它开成`；有一行同时含 strict 或 无人值守、控制面/调度器/gate-sync 之一、发布或 Issue。
**harness-guardrails.md**：`## 1.` 节里讲解锁/unlock 的那行含「答案库」，该节不再含 `status: approved`。

**scripts/gates.sh**：是否待答按答案库 `H.gate_state(main, gid)` 判断（`open` → 列出），不看卡上 `status:`。卡写 approved、库里没答 → 列出；库里已答、卡写 open → 不列出（或该行带「答案不一致」）；库卡都已答 → 不列出。每行仍以门卡号开头（`^G-xxx `）。结尾提示改为新通道，含 `answer`（`harness_lib.py answer <门卡号> <选项>`）和 `Telegram`。库位置随 `XDG_STATE_HOME`。

**范围提醒**：`pkg/bin/harness`（--help 文案）与 `pkg/scripts/gates.sh` 不在 allowed_paths，builder 需按 §9 记范围变更后再改。

## 4. 修改过程（计划 → 执行日志）
- [x] 1. tester：test_plugin 新断言 — 结果：pkg/tests/test_plugin.sh 追加 T-017 断言（打包 / --help / 文档 grep / gates.sh 按答案库）；当前 `bash pkg/tests/test_plugin.sh` → 44/66 passed（红，22 项全是待做：--prune-audit 帮助、README、human-gates §3、SKILL、guardrails §1、gates.sh）；原有断言全过
- [x] 2. 更新文档与打包 — 结果：README（安装加沙箱依赖、4.6 答案库与五通道、4.7 发布方、4.17 strict/standard 与残余风险、4.18 Telegram、4.19 doctor/down/审计、环境变量）；human-gates §3「答复处理」；human-gate SKILL 发布与 Telegram；guardrails §1 解锁看答案库；gates.sh 按 gate_state；--help 加 --prune-audit；插件 README 模板；`bash pkg/plugin/build.sh plugins/harness`
- [x] 3. 完整验证 — 结果：test-harness 306/306；test_plugin 66/66；其余 test_*.sh 全部 N/N（answers 268、audit 141、branch_protection 152、chat_answer 148、control_paths 158、doctor 109、init 34、launch 185、plugin_install 53、publish 139、serve 20、serve_answer 65、serve_needs 15、telegram 149）

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
- 最后更新：builder
- 做到哪：实现完成，全部测试绿
- 下一步：verifier
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- 《使用手册：从一个想法到上线》不在仓库里，教程只能追加在 README 4.17–4.19；外部手册需另行同步。
- 主仓库根目录的 `.claude/rules/`（dogfood 副本）仍是旧文案，不在本任务范围。

## 9. 范围变更 / 依赖变更
- 加 `pkg/bin/harness`：接口约定要求 --help 的 down 行写 --prune-audit（已批准的追加）。
- 加 `pkg/scripts/gates.sh`：接口约定要求按答案库 gate_state 判断待答（已批准的追加）。
- 加 `pkg/.claude/skills/human-gate/SKILL.md`：接口约定要求改 SKILL 的发布说法；原 allowed_paths 只覆盖 rules/。
- 无依赖变更。

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 22 项红都是文案/帮助/gates.sh 未改，非功能缺陷 | 按接口约定改文档、--help、gates.sh（调 H.gate_state，库位置随 XDG_STATE_HOME） | test_plugin 66/66，其余套件全绿 |
| 2 | 挑错 5 条文档不准：答案库路径、bot 全局唯一、setup 的 deny 含状态目录、gates.sh 提示路径（插件模式）、凭证清理名单 | 按代码（state_dir、inbox_cmd、SCRUB_*/KEEP_ENV）改 README；gates.sh 提示按 $HOOKS 输出相对路径；重建插件 | 全部套件 N/N |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
