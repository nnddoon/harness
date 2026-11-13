---
id: T-009
title: 控制路径守门与沙箱内验证
status: claimed
priority: P0
risk: high
size: M
source: human
spec: S-002
test_owner: tester
branch: task/T-009-control-paths
worktree: .claude/worktrees/T-009
session: auto
depends_on: [T-008]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/scripts/harness-loop.sh, pkg/scripts/new-task.sh, pkg/.claude/hooks/harness_lib.py, pkg/.claude/hooks/quick_check.py, pkg/cli/strict_profile.py, pkg/tests/test_control_paths.sh, pkg/tests/run.sh, pkg/tests/fake/**, pkg/scripts/test-harness.sh, pkg/.claude/hooks/gate_github.py]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-009 控制路径守门与沙箱内验证

## 1. 背景与目标
控制面不再信任 agent 分支里的控制文件，也不再在沙箱外运行 agent 写的代码。改了控制路径的分支不能被合并、推送或当成下游基线；整合验证在沙箱里、无凭证地跑。

## 2. 范围
**做：**
- `harness_lib control-diff <base> <branch>`：命中控制路径且无已批准 unlock 时列出文件
- 调度器在整合、推送、作为下游基线之前调用它；命中则任务转 blocked 并开门卡
- 整合验证改用沙箱运行器（srt）执行，环境无凭证；srt 已获允许（D-007）；未安装时调度器拒绝在 strict 下整合并提示安装命令，不自动安装
- strict 模式下 quick_check hook 不执行项目命令，改为提示 Claude 在沙箱 Bash 里跑
- 沙箱 denyWrite 补上主仓库 `.git/hooks`、`.git/config`、`.git/info`

**不做（明确排除）：**
- 不实现推送和开 PR 的迁移（T-011）

**接口约定（tester 按此写测试，builder 按此实现）**
- **control-diff**：`python3 <lib>/harness_lib.py control-diff <base> <branch> [--root DIR]`（`--root` 默认 cwd）。取 `git diff --name-only --no-renames <base>...<branch>`（三点 = 自合并基以来分支上的改动；`--no-renames` 让改名同时出现旧名和新名，删除也列出），逐个用 `matches_any(path, CONTROL_PATHS)`（`glob_to_regex` 的 `**` 语义，锚定在仓库根：`src/scripts/x.sh` 不算）筛选。stdout 每行一个命中路径，去重、排序；退出码：0 = 无命中，1 = 有命中，2 = 参数错误或 git 失败（不存在的 ref 等，stderr 说明）。调用方把**非 0 一律当作命中**（失败即拒绝）。
- 进程内：`control_diff(root, base, branch) -> list[str]`（root 可为 `Path`/`str`；git 失败抛 `LaunchError(2, …)`）。只用 `CONTROL_PATHS`（T-008 冻结清单），**不**读任务卡 `unlock:` 和门卡（分支里的门卡 Claude 能写；已批准 unlock 的豁免由 T-010 从答案库接入，Guardrail「有已批准 unlock 照常放行」届时生效）。
- **调度器接入**（harness-loop.sh / new-task.sh），基线一律 `main`：
  - (a) `finish()`：任务卡状态为 `review` 时，在整合（夜间模式）或任何后续动作之前跑 `control-diff main <任务分支>`；
  - (b) 推送任务分支 / 开 PR 之前同样调用（目前调度器不推送任务分支，T-011 落地时复用 (a) 的结果或再查一次）；推送整合分支前也跑 `control-diff main <整合分支>`，命中则不推送；
  - (c) `new-task.sh`：`HARNESS_BASE` 设了且不是 `HEAD` 时，在**任何改动之前**（登记 claimed 之前）跑 `control-diff main "$HARNESS_BASE"`；命中则 stderr 打印 `✗ 基线 <ref> 改到控制路径：<文件>`，退出 1，不登记、不建 worktree。
- **命中时（(a)）**：不合并、不推送、不作为下游基线；`set-status <TID> blocked --backlog-only`；stdout 打印 `  ✗ <TID> 改到控制路径：<文件, 逗号分隔>`；在**主仓库** `.harness/gates/G-<TID 去掉连字符>-ctl.md`（如 `G-T040-ctl.md`）写门卡（由 commit_bookkeeping 提交）：frontmatter `id: G-T040-ctl`、`task: T-040`、`kind: unlock`、`status: open`、`recommended: B`、`approve_options: [A]`、`blocks: [T-040 整合]`；正文标题含「改到控制路径」，逐行列出命中文件，选项 A = 批准这些改动（人工合并）、B = 退回重做。不计入整合失败重开次数（`.T-xxx.reopen` 不变），不影响现有整合失败重试逻辑。`.github/**` 同此规则（S-002#12）。
- **沙箱内验证**：`sandboxed_cmd(cmd: list, root) -> (argv, env)`：
  - `argv = [<runner>, "--settings", <文件>, *cmd]`，runner = 环境 `HARNESS_SRT`（默认 `srt`），按 PATH 解析；找不到 → 抛 `LaunchError(3, SRT_FIX)`（提示 `npm install -g @anthropic-ai/sandbox-runtime`）。
  - `<文件>`：`state_dir(主仓库)/srt-settings-verify.json`，权限 600，原子写入。内容只有 srt 认的两段：`{"network": {"allowedDomains", "deniedDomains"}, "filesystem": {"denyRead", "allowWrite", "denyWrite"}}`，取自 `strict_settings(root, "task")["sandbox"]`；路径 `//abs` → `/abs`（`~/` 原样，srt 会展开），去掉结尾 `/**`；`allowWrite` 额外加 `root` 本身和 `${TMPDIR:-/tmp}`（srt 默认全不可写）。因而 denyWrite ⊇ root 与主仓库下的控制路径、主仓库 `.git/hooks`、`.git/config`、`.git/info`。
  - `env = scrub_env(os.environ)`（无 GH_TOKEN 等凭证，`HARNESS_STRICT=1`）。
  - CLI：`harness_lib.py sandbox-run [--root DIR] -- <cmd…>`：在 root 下以上述 argv/env `exec`；`sandbox-run --check` 只检查 runner，打印 `ok` 退出 0，缺失打印修复办法退出 3。
- **integrate()**：合并**之前**先 `sandbox-run --check`；缺 runner → 不合并，任务保持 `review`，不增加重开计数，打印 `  ✗ 没有沙箱运行器 srt，不整合 <TID>：<SRT_FIX>`。整合验证改为 `( cd "$IWT" && $LIB sandbox-run --root "$IWT" -- bash .harness/verify.sh )`，即实际执行 `srt --settings <文件> bash .harness/verify.sh`。`sandbox_problem` 的 srt 检查也改按 `HARNESS_SRT` 解析。
- **quick_check.py**：环境 `HARNESS_STRICT=1` 时**不运行任何子进程里的项目命令**（不执行 `.harness/quick-check.sh`）；现有跳过规则不变（未配置、`.harness/` 内、跳过的扩展名 → 无输出退出 0）；否则在 stdout 输出 `{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "[harness] strict：hook 不在沙箱外运行项目命令，请你自己在 Bash 里运行：bash .harness/quick-check.sh <相对路径>"}}`，退出 0。
- 测试接口：`HARNESS_SRT`、`HARNESS_PLATFORM`、`XDG_STATE_HOME` 可覆盖；测试用假 srt 记录 argv/env 后去掉 `--settings <文件>` 再 exec 其余参数。


**接口约定 v2（对抗审查第 1 轮后修订，见 §13）**
- **整合验证在一次性导出目录里跑，没有 git 目录**（#1 #5）：合并后得到 `<merged>` 提交，`git archive <merged>` 解到 `state_dir(主仓库)/verify-*` 临时目录（权限 700），在那里以 srt 运行 `bash .harness/verify.sh`，结束后（无论成败）删除。CLI：`harness_lib.py sandbox-run --root <主仓库或其 worktree> --export <commit> -- <cmd…>`：导出 → 子进程运行（cwd = 导出目录）→ 删除 → 以 cmd 的退出码退出；`<commit>` 无效 → 退出 2、不运行。进程内：`sandboxed_cmd(cmd, root, workdir=None)`，给了 `workdir` 时 srt `allowWrite` **只有** `workdir` 和 `${TMPDIR:-/tmp}`（不得含 root、任何含 `/.git` 的路径）。`denyRead`/`denyWrite` 仍取自 `strict_settings(root)`（root = 整合 worktree）。整合 worktree 因此不会留下验证产生的未跟踪文件。
- **控制面的 git 调用一律加固**（#1）：`harness-loop.sh`、`new-task.sh` 里每一次 git 调用都经 `GIT=(git -c core.hooksPath=/dev/null -c core.fsmonitor=false)`（含 `status`、`rev-parse` 等只读命令）；`gate_github.push_assets` 的 git 调用同样带这两个 `-c`。合并（`merge`）另加 `-c filter.lfs.process= -c filter.lfs.smudge= -c filter.lfs.clean=`，环境 `GIT_LFS_SKIP_SMUDGE=1`（#3）。harness_lib.py 里的只读 git 调用不在此列。
- **整合 worktree 归属检查**（#1）：夜间模式在启动时、以及每次 `integrate()` 之前，用 `git -C "$IWT" rev-parse --path-format=absolute --git-common-dir` 取公共 git 目录，realpath 必须等于 `$ROOT/.git`；不等 → 打印 `✗ 整合 worktree <IWT> 的 git 目录不是本仓库的 .git，拒绝使用`，启动时退出 2（不派发任何任务）；`integrate()` 里则不合并、任务保持 review。该检查之前不在 `$IWT` 里跑任何其他 git 命令。
- **push_assets（任务分支推送）**（#7）：主仓库 = worktree 路径 `<主仓库>/.claude/worktrees/<名字>` 的上两级（不问 worktree 里的 git）；worktree 的公共 git 目录 realpath 不等于 `<主仓库>/.git` → 不做任何 git 写操作、不推送；`control-diff main <branch> --root <主仓库>` 非 0 → 不推送。
- **教训同步改到合并之后**（#2）：`finish()` 不再调用 `lessons`；`sync-merged` 把新标记为 done 的任务，从**主干上**（合并后）的任务卡 §12 同步到 `.claude/rules/lessons.md`（格式不变：`- <教训>（T-xxx）`）。`harness_lib.py lessons <TID> <dir>` CLI 保留。
- **控制路径扩大**（#3）：control-diff 另外命中 `.claude/**`、`**/CLAUDE.md`、`CLAUDE.local.md`、`**/.gitattributes`、`.gitmodules`、`.lfsconfig`。取舍：沙箱 denyWrite 只能写字面路径，且任务 worktree 本身就在 `<主仓库>/.claude/worktrees/` 下，所以 `CONTROL_PATHS`（沙箱 / 权限规则用）只加字面项 `CLAUDE.local.md .gitmodules .lfsconfig .claude/output-styles/**`；通配项放在只供 control-diff 用的扩展清单里（如 `CONTROL_GLOBS = CONTROL_PATHS + [".claude/**", "**/CLAUDE.md", "**/.gitattributes"]`）。test_launch.sh 必须保持全绿。
- **验证环境无保留名单**（#4）：`sandboxed_cmd` 的 env 不保留 `KEEP_ENV` 和 `HARNESS_KEEP_ENV`：`ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN` 和带账号密码的 `*_PROXY` 一律删除；srt `denyRead` 另加 `~/.claude`、`~/.claude.json`。Claude 自己的启动（launch）不变。
- **分支来自主干任务卡、只解析一次**（#6）：`finish()` 读**主仓库**任务卡的 `branch:`（缺省规则同 new-task.sh），`git rev-parse --verify refs/heads/<branch>^{commit}` 得到 SHA，之后 control-diff、合并都用这个 SHA（不看 worktree 的 HEAD / 当前分支）。合并后再跑 `control-diff <pre> <merged>`，命中 → 撤回合并、按命中处理。
- **基线检查**（#7 #9）：`new-task.sh` 把基线（`HARNESS_BASE`，默认 `HEAD`）解析成 SHA，只要它不等于 `main` 的 SHA 就跑 `control-diff main <SHA>`（与 depends_on 无关；夜间模式下每个任务都以整合分支为基线，都要过检查）。
- **非 UTF-8 文件名**（#8）：git 输出按字节读、用 `surrogateescape` 解码；`control_diff()` 返回含代理字符的 str（如 `scripts/\udcff.sh`）；CLI 用 `surrogateescape` 写回原字节，退出 1，不出 traceback。
- **验证的网络白名单取自主干**（#10）：`stack_domains` 用主仓库（main 检出）的清单文件，不用合并后分支的。

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 为什么要 diff 检查 | git hash-object/update-index 可以不写文件路径就提交控制文件 | 挑错 S#3 |
| 验证为何要进沙箱 | verify.sh 运行 agent 写的测试，原来带着你的凭证在沙箱外跑 | 挑错 S#1 S#2，harness-loop.sh:96 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | integrate()、HARNESS_BASE 选择、quick_check.py | harness-loop.sh:77-110；quick_check.py:32-36 |
| 受影响测试 | 整合相关用例改用假 srt | pkg/scripts/test-harness.sh |
| 依赖变更 | 控制面可选使用 srt（你电脑上的工具，非项目依赖） | G-S002-1 |
| 风险 | high | - |

## 4. 修改过程（计划 → 执行日志）
- [x] 1. tester：构造改了 .harness/verify.sh、.github/workflows、scripts/ 的分支（含用 git plumbing 提交的），断言调度器拒绝；假 verify.sh 打印环境，断言无凭证且经 srt 调用 — 结果：pkg/tests/test_control_paths.sh 88 项（现 78 项失败）；pkg/scripts/test-harness.sh 新增「control paths (T-009)」34 项（现 27 项失败），原 207 项仍全过；假 srt 改为记录后转执行。第 2 轮（接口约定 v2）：test_control_paths 增至 140 项（v2 新增 52 项，对 7b0882f 失败 42 项）；test-harness 再增 29 项（失败 20 项，其余 9 项为覆盖已有守门的用例），原 241 项全过
- [x] 2. 实现 control-diff 与调度器接入 — 结果：harness_lib `control_diff`/`control-diff`；harness-loop finish() 在 review/done 时查（主仓库里查，失败即命中）→ blocked + G-Txxx-ctl；推送整合分支前再查；new-task.sh 查 HARNESS_BASE
- [x] 3. 验证进沙箱、quick_check strict 分支 — 结果：`sandboxed_cmd`/`sandbox-run [--check]`；integrate() 先 --check，验证经 srt；quick_check strict 只给提示。test_control_paths 88/88，test-harness 241/241
- [ ] 4. 完整验证 + 对抗审查 — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 改了控制路径（含 git plumbing 提交）的分支：不合并、不推送、不作为下游基线，任务 blocked 且有门卡（S-002#6） — 证据：
- [ ] A2. 改了 .github/** 的分支不推送（S-002#12） — 证据：
- [ ] A3. 整合验证经 srt 调用，验证进程环境无凭证（S-002#7） — 证据：
- [ ] A4. strict 模式下 quick_check hook 不执行任何项目命令（S-002#7） — 证据：
- [ ] A5. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A6. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- [ ] B1. 在你的电脑上：一个改了 .harness/verify.sh 的任务分支，夜间模式不合并并开出门卡（S-002#6 人工） — 门卡：

## 6. Guardrails（本任务特有）
- 有已批准 unlock 门卡的控制路径改动照常放行
- 不弱化现有整合失败重试逻辑

## 7. 当前进展（中断/换对话时更新）
- 最后更新：2026-11-13（builder）
- 做到哪：步骤 2、3 完成，测试全绿
- 下一步：步骤 4 完整验证 + 对抗审查
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- exclude_placeholders 对 worktree 内路径按主仓库算相对名（`/.claude/worktrees/T-xxx/...`），多余但无害。

## 9. 范围变更 / 依赖变更
- builder：`plugins/harness/**` 由 `bash pkg/plugin/build.sh plugins/harness` 重新生成（test_plugin_install 要求与源码一致），不手改。
- allowed_paths 加 `pkg/scripts/test-harness.sh`：整合验证改走 srt 后，自测里原来「直接 exit 0」的假 srt 必须改成记录并转执行，否则夜间模式的 red 用例失去意义；调度器相关新用例也放在那里（tester）。
- allowed_paths 加 `pkg/.claude/hooks/gate_github.py`：`push_assets` 在 hook 里推送任务分支，属于「推送前查控制路径」和 git 加固的范围（对抗审查第 1 轮 #1 #7）。

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 按接口约定实现 control-diff / sandboxed_cmd / sandbox-run / quick_check strict 即可 | harness_lib、quick_check | test_control_paths 88/88；test-harness 剩 3 项（ctl .github） |
| 2 | T-045 的 .github/workflows/a.yml 没进提交：strict 启动把不存在的控制路径 `/.github` 写进 .git/info/exclude，`git add -A` 忽略了真目录 | exclude_placeholders 每项再加 `!<name>/`：只忽略占位文件，真目录 git 看得见 | 241/241 |
| 3 | 换成符号链接的控制目录（`.claude/commands -> src/x`、`.harness -> src`）只在 diff 里出现目录名本身，`**` 匹配不到 | control_diff 额外把控制路径的上级目录本身算命中；比对前 NFC+casefold（大小写不敏感的文件系统） | 手工验证命中，测试仍全绿 |
| 4 | 第 2 轮：按接口约定 v2 实现（导出目录验证、git 加固、commondir 检查、教训改由 sync-merged、扩大清单、验证环境无保留名单、卡片分支 SHA + 合并后复查、surrogateescape、HEAD≠main 也查基线、白名单取自主干、push_assets 守门） | harness_lib、harness-loop、new-task、gate_github | test-harness 剩 sync-merged / night 等 25 项：new-task 在登记提交之前解析基线 SHA，worktree 少了登记提交，合并 backlog 冲突 |
| 5 | 基线 SHA 只用于检查；建 worktree 仍用 `$BASE`（期间只多了控制面自己的登记提交 / 合并 main） | new-task.sh | 270/270，140/140 |
| 6 | 导出目录在 `$XDG_STATE_HOME/harness`（strict 的 denyRead）里，真 srt 下验证读不到自己的文件 | srt_settings 把包含导出目录的 denyRead 项换成沿途同级条目；导出模式设 GIT_CEILING_DIRECTORIES | 全绿；verify.sh 0 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
