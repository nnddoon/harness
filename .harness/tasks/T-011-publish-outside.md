---
id: T-011
title: 发布与推送移到控制面
status: ready
priority: P1
risk: high
size: M
source: human
spec: S-002
test_owner: tester
branch: task/T-011-publish-outside
worktree: .claude/worktrees/T-011
session: auto
depends_on: [T-009, T-010]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/.claude/hooks/gate_github.py, pkg/.claude/hooks/harness_lib.py, pkg/scripts/harness-loop.sh, pkg/scripts/gate-sync.sh, pkg/.claude/skills/task-close/SKILL.md, pkg/.claude/settings.json, pkg/tests/test_publish.sh, pkg/tests/run.sh, pkg/tests/fake/**, plugins/harness/**, pkg/.claude/hooks/guard_bash.py]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-011 发布与推送移到控制面

## 1. 背景与目标
strict 模式下 Claude 和它的 hooks 不做任何 GitHub 写操作；推分支、开 PR、开门卡 Issue、推素材由调度器或 gate-sync 在控制面完成。

## 2. 范围
**做：**
- goal_prompt 与 task-close：strict 时只写交接包和合并门卡草稿，不推不开 PR
- 调度器 finish()：控制路径检查通过后推分支、开 PR、把 PR 号写入答案库
- 门卡 Issue 发布与素材推送从 PostToolUse hook 移到 gate-sync；standard 模式保留旧行为

**不做（明确排除）：**
- 不改 standard 模式下的交互流程

## 接口约定（tester 写，builder 按此实现；测试 pkg/tests/test_publish.sh）
- **strict 判定**：环境变量 `HARNESS_STRICT=1`（启动器 scrub_env 设置）。调度器（harness-loop）与 `gate_github.start_run` 启动的运行一律 strict。
- **goal_prompt**：`goal_prompt(tid, note="", strict=False)`；CLI `harness_lib.py goal <TID> [--note N] [--strict]`。
  strict 文本必须含「不推送」「不开 PR」和合并门卡草稿名 `G-<T无连字符>-merge`（如 `G-T050-merge`），仍含 `/task-close <TID>`；standard 输出与现在逐字相同。
  harness-loop 的 `launch()` 用 `--strict`；`gate_github.start_run` 传 `strict=True`。
- **task-close SKILL.md 第 4 步**：写明 `HARNESS_STRICT=1` 时只写交接包和合并门卡草稿 `.harness/gates/G-<T无连字符>-merge.md`（kind: irreversible，`pr:` 留空），不推送、不 `gh pr create`；否则保持现有流程（推送 + `gh pr create`）。
- **gate_github.py hook（PostToolUse）**：`HARNESS_STRICT=1` 时直接返回：不调用 gh（连只读也不调）、不 git commit/push 素材、不改门卡、不写答案库（auto_answer 也交给 gate-sync）、不输出。standard 行为不变；`publish` 子命令不变。
- **finish()（非整合模式，状态 review，task-branch + control-diff 通过之后）**：在主仓库 `git push origin <SHA>:refs/heads/<branch>`（SHA = finish 已解析并检查过的那个；没有 origin 就跳过）→ `gh pr create --base main --head <branch> …`（每任务一次）→ 从输出解析 PR 号 → `record_pr(main, "G-<T无连字符>-merge", n)`（合并门卡草稿不存在时调度器在主仓库写一张 kind irreversible）。push / pr create 失败：任务保持 review、不记 PR、打日志。control-diff 命中或 blocked：不推、不开 PR。整合模式维持现状（只推整合分支、开整合 PR）。
- **gate-sync（`gate_github.py sync`，含 harness-loop 开头那次）**：在控制面发布每张 open、尚未发布（无 issue 映射）的门卡：有 `read_pr` 的挂到 PR（pr comment，不开 Issue），合并门卡没有 PR 映射时不发布；其余 `issue create` + `record_issue`。素材若不在远端任务分支上，由控制面从主仓库按 SHA、先 control-diff 再推送。重复运行不重复发布。
- **测试替身**：`pkg/tests/fake/gh_publish.py`（有状态，calls.jsonl 记 argv / HARNESS_FAKE_CLAUDE / HARNESS_STRICT / 是否写调用；`pr create` 号从 101 起）；假远端 = 裸仓库 + `hooks/update` 记录每次 ref 更新；git 记录器记录每次 git 调用。

### 接口约定 v2（挑错第 1 轮；测试 test_publish.sh「接口约定 v2」一节）
1. **PR 映射没有 Claude 能调的写入口**：`harness_lib.py merge-pr T-xxx <N>` 这类写形式删除（调用时退出非 0、什么都不写；只读形式可留）。
   调度器经内部调用（`python3 -B -c …record_merge_pr…` 之类）写；guard_bash 无论如何拒绝含 `merge-pr` 的 harness_lib.py 调用和含 `record_merge_pr` 的命令（allowed_paths 加 guard_bash.py）。
   publish_task 对已记录的映射先 `gh pr view <N>` 核对：headRefName ≠ 任务分支 → 视为伪造，不信，照常开 PR 并改记新 PR（控制面可覆盖映射）；之后 gate-sync 不因旧 PR 批准合并门卡。
2. **发布认领**：hook（standard）和 gate-sync 两条路径都在 `gh issue create` 之前以 O_EXCL 建 `answers/<GID>.pubclaim.json`；建不成（已有认领）就不开 Issue。并发的两个发布者只开 1 个 Issue。
3. **谁的门卡由 gate-sync 发布**：调度器自己的门卡（`G-Txxx-ctl`、`G-Txxx-merge`；后者仍要有 PR 映射才挂 PR）总是由 gate-sync 发布，与 strict 判定无关。
   其余门卡只在「strict 启动过的 checkout」发布：启动器按 checkout（根目录）记录每次启动（strict 或 standard）；strict 判定认 `strict-settings-task-<TID>.json`、`strict-settings-plan-*.json` 和 `strict-settings.json`（不带 --task 的 strict 启动），
   但某 checkout 的 strict 记录早于该 checkout 之后的 standard 启动、或距今超过 7 天（「今」= `HARNESS_NOW`（Unix 秒）若设置）就不算。一个 checkout 的 strict 启动不影响别的 checkout。
4. **publish_task 恢复**：`gh pr create` 失败 → `gh pr list --head <分支>`（OPEN）找作者 = 控制面登录名（`gh api user`，用控制面的 token：设了 HARNESS_GH_TOKEN 就用它）的 PR，只记录它；别人开的不记，任务保持 review。已记录的 PR 是 CLOSED → 开新 PR 并改记新号。
5. 推送失败或开 PR 失败（且无可恢复的 PR）：任务保持 review，什么都不记；整合模式不变（不推任务分支、不开任务 PR，只推整合分支、开 1 个整合 PR）；第二次 gate-sync 不产生新的 Issue / 评论 / PR 写调用；合并门卡永不 auto_answer（Claude 把草稿 kind 写成已放权类别也不行）；从没 strict 启动过的 checkout 里没经 hook 的门卡 gate-sync 不发布；`G-Txxx-ctl` 由 gate-sync 发布且只发一次。
7. **合并门卡草稿原子写**：调度器写主仓库的 `G-Txxx-merge.md` 用临时文件 + `os.replace`（不顺着符号链接写到别处，不留临时文件），kind irreversible。
（第 6 项 human-gate SKILL 文档归 T-017。）

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| hook 为什么也不行 | hook 在沙箱外、继承环境，可用 git 凭证助手 | 挑错 F#2 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | goal_prompt、task-close 第 4 步、finish()、整合 PR、publish/push_assets | harness_lib.py:160-166；task-close/SKILL.md:25；harness-loop.sh:215-226；gate_github.py:133-198 |
| 受影响测试 | gate 发布相关用例 | pkg/tests |
| 风险 | high | - |

## 4. 修改过程（计划 → 执行日志）
- [x] 1. tester：假 gh / 假远端记录写调用，strict 下 Claude 侧为 0、调度器侧完成推送与 PR — 结果：pkg/tests/test_publish.sh 52 项，现状 13/52（红，39 项按预期失败）；v2：107 项，对 c0e0485 为 84/107（23 项按预期失败）
- [x] 2. 改 goal 与 task-close — 结果：`goal_prompt(strict=)` / `goal --strict`；task-close 第 4 步分 strict / 标准两支
- [x] 3. 调度器与 gate-sync 接管发布 — 结果：finish→publish_task（主仓库按 SHA 推、pr create、`merge-pr` 记 PR）；hook strict 直接返回；sync 先 publish_pending（控制面、素材按 SHA 推）。test_publish 52/52，自测 306/306，其余套件全绿
- [ ] 4. 完整验证 + 对抗审查 — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. strict 模式一次完整任务：Claude 及 hooks 对假 gh/假远端写调用 0 次；调度器推分支、开 PR、开门卡 Issue 各 1 次（S-002#11） — 证据：
- [ ] A2. standard 模式行为与现在一致（现有测试通过） — 证据：
- [ ] A3. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A4. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- （无）

## 6. Guardrails（本任务特有）
- 不改 decisions.md 格式
- 不在 standard 模式下改变用户可见流程

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- 

## 9. 范围变更 / 依赖变更
- allowed_paths 加 `plugins/harness/**`：插件包由 `pkg/plugin/build.sh plugins/harness` 生成，test_plugin_install 检查它是最新的。
- gate-sync 只在跑过 strict Claude 的 checkout 上发布门卡（看启动器写的 `strict-settings-task-<TID>.json` / `strict-settings-plan-*.json`），外加调度器已记 PR 的门卡；只交互运行过的 checkout 维持 hook 发布（否则自测里未经 hook 的门卡会被发布，标准模式行为变了）。
- 合并门卡一律不走 auto_answer。

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 按接口约定实现即可 | goal/task-close/hook/finish/gate-sync | test_publish 52/52；自测 298/306：gate-sync 把未经 hook 的 G-T001-2 发成 Issue，打乱编号 |
| 2 | 控制面只发布 strict 运行过的 checkout 的门卡 | 启动器写 state_dir/strict-roots 标记 | 自测 306/306；test_launch 184/185（state_dir 多出目录） |
| 3 | 改用启动器自己的 strict-settings-*.json 作判据，不新增文件 | strict_launched() | 全部套件全绿 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
