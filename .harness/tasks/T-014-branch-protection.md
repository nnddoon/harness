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
allowed_paths: [pkg/cli/init_cmd.py, pkg/plugin/skills/setup/SKILL.md, pkg/tests/test_init.sh, pkg/tests/test_branch_protection.sh, pkg/tests/fake/**, plugins/harness/**]
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

## 接口约定（tester 写，实现照此做；测试：pkg/tests/test_branch_protection.sh，假 gh：pkg/tests/fake/gh）
**何时跑：** `harness init`（含 `--plugin`，即 /harness:setup）装完文件后做一次分支保护检查；`--dry-run` 也做检查（只读调用），但只打印「会做什么」，不写任何文件。检查结果不改变 init 的退出码。

**gh 从哪来：** `$HARNESS_GH`（默认 `gh`）。设置了 `HARNESS_GH` 时只用它，不回退到 PATH 里的 gh。

**只读调用（只允许这些；任何 `-X/--method` 非 GET、带 `-f/-F/--field/--raw-field/--input`（gh 会默认 POST）、或 `repo edit` 之类的写命令都算写调用，必须 0 次）：**
1. `gh repo view --json visibility,owner,nameWithOwner,defaultBranchRef` —— 在目标仓库目录里执行（cwd = 仓库根），输出 JSON 由 Python 解析，不用 `--jq` / `--template`。取 `owner.login`、`nameWithOwner`（`{o}/{r}`）、`defaultBranchRef.name`（`{b}`）、`visibility`。
2. `gh api repos/{o}/{r}/branches/{b}/protection`（GET）。gh 出错时退出码非 0，stdout 是响应 JSON（含 `"message"`、`"status"`），stderr 是 `gh: <message> (HTTP <code>)`。
   （可选：`gh auth status`；可选 `-i/--include` 看状态码。）

**判定与输出（每种情形恰好一行含「分支保护」）：**
| 情形 | 判定 | 输出（一行） | 文件 |
|---|---|---|---|
| a. 能开且未开 | 保护 API 404（Branch not protected），公开或私有均可 | `→ 分支保护可以开：已开门卡 .harness/gates/G-SETUP-bp.md，批准后照门卡里的命令执行` | 写门卡（已存在则不动） |
| 已开 | 保护 API 200 | `✓ 分支保护已开启：{o}/{r} 的 {b}` | 无 |
| b. 计划不支持 | 保护 API 403 且 message 含 `Upgrade to GitHub Pro`（或 `upgrade` + `Pro`/`Team`） | `• 分支保护开不了：私有仓库在 GitHub Free 上没有分支保护（需要 Pro/Team）；strict 模式已在本机挡住合并。` | 无 |
| c. 无法检查 | gh 不存在、未登录、没有远端、`repo view` 失败、其他 403（如无管理员权限）或其他错误 | `跳过分支保护检查：<原因>` | 无 |
| dry-run | 同上判定 | 情形 a 时打印一行含 `G-SETUP-bp`（「会开门卡 …」），其他情形打印同上的那一行 | 无 |

**门卡 `.harness/gates/G-SETUP-bp.md`（情形 a）：** 按 `.harness/gates/_TEMPLATE.md` 的格式；frontmatter：`id: G-SETUP-bp`、`task:`（空，setup 不属于任务）、`kind: external`、`status: open`、`recommended: A`、`approve_options: [A]`。重跑 init 时门卡已存在 → 不覆盖、不新开第二张。正文的「怎么检查」代码块里包含下面两条命令，各占一行、可直接复制（`{o}/{r}/{b}` 用 gh 返回的真实值）：
```bash
gh api -X PUT repos/{o}/{r}/branches/{b}/protection -H "Accept: application/vnd.github+json" -F required_status_checks=null -F enforce_admins=true -F "required_pull_request_reviews[required_approving_review_count]=1" -F restrictions=null -F allow_force_pushes=false -F allow_deletions=false
gh api -X PUT repos/{o}/{r}/actions/permissions/workflow -f default_workflow_permissions=read
```
选项：A（推荐）由你执行这两条命令开启（{b} 必须走 PR、1 个审批、禁止强推和删除、管理员也受约束；Actions 默认只读）；B 先不开。

**setup skill：** `pkg/plugin/skills/setup/SKILL.md` 提到分支保护那一行要原样转告用户（dry-run 和接入两步都是）。

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
- [x] 1. tester：假 gh 三种情形（公开、私有+Pro、私有+Free） — 结果：接口约定已写；pkg/tests/fake/gh + pkg/tests/test_branch_protection.sh，未实现时 `bash pkg/tests/test_branch_protection.sh` → 43/82 passed（红，失败项全是待实现的门卡/提示行/setup 文案）
- [x] 2. 实现 — 结果：init_cmd.py 加只读检查 check_branch_protection + branch_protection（dry-run 只打印）、门卡 G-SETUP-bp（已存在不动）；setup SKILL.md 两步都原样转告「分支保护」行；重建 plugins/harness。test_branch_protection 82/82，verify.sh exit 0
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
- 最后更新：2026-11-13
- 做到哪：步骤 2 完成，全绿已提交
- 下一步：步骤 3 verifier + 对抗审查（risk medium）
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- 

## 9. 范围变更 / 依赖变更
- 新增 `pkg/tests/test_branch_protection.sh`（按派发要求单独成文件），不在 allowed_paths 内（只列了 pkg/tests/test_init.sh、pkg/tests/fake/**）：需把它加进 allowed_paths，否则 A3 会判越界。仅 1 个测试文件，未超 3 个文件。
- allowed_paths 加入 `pkg/tests/test_branch_protection.sh`、`pkg/tests/fake/**`、`plugins/harness/**`（后者：改了 setup SKILL.md 与 init_cmd.py 后须重建已提交的插件目录，否则 test_plugin_install 判过期）。调度器已批准。

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 按接口约定实现即可通过 | init_cmd.py：HARNESS_GH 只用它；无远端不调 gh；repo view + GET protection；404 not protected→门卡，403 upgrade Pro/Team→一句话，200→✓，其余→跳过 | 81/82：缺 setup SKILL.md 文案 |
| 2 | SKILL.md 未提分支保护 | dry-run 与接入两步加「分支保护」行原样转告，并禁止代执行 PUT | 82/82；build.sh 后 verify.sh exit 0 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
