---
id: T-007
title: 插件一行安装：marketplace + /harness:setup + init --plugin
status: review
priority: P1
risk: medium
size: M
source: human
spec: S-001
test_owner: tester          # tester = 测试只由 tester 子代理写（默认）| any = 小修可自己改测试（需在对齐时说明）
branch: task/T-007-plugin-install
worktree: .claude/worktrees/T-007
session: auto               # auto = 由调度规则决定（harness_lib.py decide）| same | new = 人工强制
depends_on: [T-005]
context_files: [docs/specs/S-001-harness-v01.md, .harness/handoffs/T-005.md]
allowed_paths: [.claude-plugin/marketplace.json, plugins/harness/**, pkg/plugin/**, pkg/cli/init_cmd.py, pkg/scripts/gate-sync.sh, pkg/scripts/harness-loop.sh, pkg/scripts/new-task.sh, pkg/.claude/hooks/stop_gate.py, pkg/.claude/hooks/permission_allow.py, pkg/.claude/hooks/harness_lib.py, pkg/.harness/locks.txt, pkg/tests/test_plugin_install.sh, pkg/tests/test_plugin.sh, pkg/.claude/hooks/guard_bash.py, pkg/cli/serve_cmd.py]
locked_paths: []            # 本任务额外禁止修改的 glob（全局 locks.txt 之外）
unlock: []                  # 需要临时解锁的路径（必须有对应 approved 的 unlock 人工门）
gates: []                   # 关联人工门，例如 [G-T013-1]
auto_ok: no                 # yes = 低风险可自动批准进入 ready（仅 groom 提议使用）
---

# T-007 插件一行安装：marketplace + /harness:setup + init --plugin

## 1. 背景与目标
用户要求（D-004）：插件一行安装。做完后：`claude plugin marketplace add nnddoon/harness && claude plugin install harness@harness` 一行装好；在任何仓库里 `/harness:setup` 接入，仓库里不再需要 .claude/hooks、skills、agents。

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
- [x] 1. tester：先写 test_plugin_install.sh（31 项），8/31（红）
- [x] 2. builder：lib_cmd、脚本按 .claude/hooks → .harness/lib 查找、init --plugin/--dry-run、/harness:setup、build 的 payload 与命名空间、marketplace.json、plugins/harness
- [x] 3. 对抗审查：3 个独立 critic 子代理（haiku），我做裁判，8 条成立 → 先补 22 个测试（红）再修
- [x] 4. 验收与范围检查

## 5. 验收标准
**A. 机器可验证（每项附证据）**
- [x] A1 一行命令从本仓库的 marketplace 装上插件（实测 claude plugin marketplace add + install 成功） — 证据：本仓库为 marketplace：`HOME=<临时> claude plugin marketplace add <仓库>` 与 `claude plugin install harness@harness` 均 exit 0，`claude plugin list` 列出 harness（测试「one-line install from the marketplace」「installed plugin listed」）；从 GitHub 安装在合并进 main 后验证
- [x] A2 `claude plugin validate` 对插件和 marketplace 都通过；仓库里提交的 plugins/harness 与重新构建的结果一致 — 证据：「claude plugin validate: marketplace」通过；「committed plugin is up to date with a fresh build」diff 为空
- [x] A3 插件内有 /harness:setup；init --plugin 只装 .harness/、scripts/、CLAUDE.md、规则和权限 deny 列表，库放 .harness/lib/，不装 hooks/skills/agents；--dry-run 不写任何文件 — 证据：「setup skill packaged」「dry run writes nothing」「no repo hooks/skills/agents」「library copied to .harness/lib」「developer-only scripts are not installed」通过
- [x] A4 插件模式的仓库里：scripts 正常运行；插件的护栏生效（含 .harness/lib 被冻结）；提示文字里的命令指向 .harness/lib；只读命令自动放行 — 证据：「scheduler dry run works without repo hooks」「board works from the lib copy」「plugin guard: force push denied」「quote-split trust --apply still denied」「lib copy frozen」「read-only lib command auto-allowed」「state-changing subcommand is not auto-allowed」「installed text points at the lib copy」「dashboard works in a plugin-mode repo」通过
- [x] A5 已有 settings.json 时只合并 deny 列表、不覆盖；仓库里已有 harness hooks 时提示会重复 — 证据：「existing allow kept」「existing deny kept, harness deny merged once」「warns about duplicate hooks」「odd settings … finishes and explains」×3「settings with a BOM still merged」通过；升级：「untouched script updated」「your edited script kept」「new version placed beside it」「your state files untouched」通过
- [x] A6 `bash pkg/tests/run.sh` 与 harness 自测全过 — 证据：`bash pkg/tests/run.sh` → 34/19/53/20/49/15 全过；harness 自测 201/201

**B. 需要人确认**
- [ ] B1 你在自己电脑上跑一次一行安装 + /harness:setup

## 6. Guardrails（本任务特有）
- 不改：<例如 播放器对外事件名 `onRateChange` 的签名（T-010 已交付给统计模块）>
- 不引入：<例如 新的 UI 库>
- 兼容：<例如 保持 iOS Safari 15 可用>

## 7. 当前进展（中断/换对话时更新）
- 2026-11-12 完成，进入 review。分支 task/T-007-plugin-install。按 D-004 全绿后合进 main。

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- 残余：仓库模式的 settings.json 里本来就有 `Bash(python3 .claude/hooks/harness_lib.py *)` 的放行规则（T-007 之前就有），所有子命令都不弹确认；危险子命令仍由 guard 拦。
- 残余：CRLF 换行的 locks.txt 追加后会混用换行（不影响解析）。
- B1 要你在自己电脑上验证：这台机器的 claude 没登录，不能真的在会话里输入 /harness:setup；已验证的是插件能安装、`claude plugin details` 能列出 skills。

## 9. 范围变更 / 依赖变更
- 2026-11-12 allowed_paths 加入 pkg/.claude/hooks/guard_bash.py：挑错发现用引号拆开的 `--app""ly` 能绕过护栏（T-007 之前就存在，但插件模式让它更容易被自动放行），护栏改为对去掉引号后的每一段也检查。
- 同日加入 pkg/cli/serve_cmd.py：插件模式的仓库里看板找不到库（只多了两个查找位置）。

## 10. Verifier 结论
- 结论：PASS
- 说明：A1–A6 全过（A1 的 GitHub 路径在合并后实测）；范围扩展登记第 9 节；测试只改了 T-005 的技能计数（插件新增 setup）与本任务一条越界的检查。

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 插件模式只要装 .harness 和 scripts | 首版 | 31/31，但 3 个 critic 找出 8 条成立问题 |
| 2 | 补 22 个测试后修 | 修复脚本 | 53/53；全量 190/190 + 201/201 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
| 1 | 3 | 8 | 8 | 3 个独立 critic 子代理（haiku），我做裁判。成立并已修：引号拆分绕过护栏（高）；看板在插件模式找不到库；装进仓库的 CLAUDE.md/模板仍指向 .claude/hooks 且命令没加命名空间；开发用脚本被装进用户仓库；奇怪的 settings.json 让安装半途崩溃、--target 缺值报栈；「重跑即可升级」不成立 → 加安装清单，你没改过的升级、改过的放 .harness-new；插件 README 命名空间；自动放行收窄到只读子命令，并认插件自己的库路径。未能在此验证：真实会话里输入 /harness:setup（记 B1） |
