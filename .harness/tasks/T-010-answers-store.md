---
id: T-010
title: 答案库与门卡语义
status: in_progress
priority: P0
risk: high
size: M
source: human
spec: S-002
test_owner: tester
branch: task/T-010-answers-store
worktree: .claude/worktrees/T-010
session: auto
depends_on: [T-008]
context_files: [docs/specs/S-002-hard-boundaries.md]
allowed_paths: [pkg/.claude/hooks/gate_github.py, pkg/.claude/hooks/harness_lib.py, pkg/cli/serve_cmd.py, pkg/cli/answers.py, pkg/.claude/skills/human-gate/SKILL.md, pkg/.claude/rules/human-gates.md, pkg/.claude/hooks/guard_bash.py, pkg/.claude/hooks/protect_paths.py, pkg/scripts/test-harness.sh, pkg/.harness/gates/_TEMPLATE.md, pkg/tests/test_answers.sh, pkg/tests/test_serve_answer.sh, pkg/tests/run.sh, pkg/tests/fake/**, plugins/harness/**, docs/specs/S-002-hard-boundaries.md]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-010 答案库与门卡语义

## 1. 背景与目标
门卡答案只认仓库外的答案库，「哪个选项算批准」由控制面决定。修掉 v0.1 的三个漏洞（旧 PR 冒充批准、伪造 Issue 标记、接续提示伪造答复）。

## 2. 范围
**做：**
- `pkg/cli/answers.py`：唯一写入入口 `record(gid, letter, note, via)`，存 `$XDG_STATE_HOME/harness/<仓库>/answers/`；同一门卡只认第一次
- 终端、看板、GitHub 同步改走它；门卡 `answer:` 与 decisions.md 由控制面写镜像
- 门卡语义：批准项固定 A；then 只允许 ready；pr 只认控制面为该任务开的 PR；门卡号↔Issue 号在发布时记入库，不再解析正文；渲染时去掉正文里的 `<!--`
- resume_pending 移入库；自动决定由控制面检查 auto-decide.txt 后写入
- 迁移 v0.1 已有答案；human-gate skill 与规则改为 Claude 只开卡、不写答案
- 启动器的 unlock：T-008 在 strict 下让 unlock 一律不生效；改为从答案库读取已批准的 unlock 门卡后放开对应路径（harness_lib.strict_settings）

**不做（明确排除）：**
- 不实现对话与 Telegram 通道（T-015、T-016）
- 不改发布时机（T-011）

## 接口约定（tester 定，测试 pkg/tests/test_answers.sh 按此断言）
**答案库**（在 `harness_lib.py`，两种安装方式都有；替代 §2 的 `pkg/cli/answers.py`，见 §9）
- 目录 `answers_dir(main) = state_dir(main)/answers/`（0700）。每张门卡一个 `<GID>.json`：
  `{gid, letter, note, via, at, approved, task, kind, paths}`。`approved` ⇔ `letter == "A"`（卡上 `approve_options` 一律忽略）。
  `task`/`kind` 在写入时从门卡快照；`kind: unlock` 时 `paths` = 当时任务卡的 `unlock:`（之后改卡不影响）。
- `record_answer(main, gid, letter, note, via) -> bool`：首答生效（`O_EXCL` 原子创建），已有答案返回 False 且不改任何东西；
  gid 必须匹配 `^G-[A-Za-z0-9]+-[A-Za-z0-9-]+$`，否则 False 且不写文件。门卡在 main 的各 worktree 里找（任务 worktree 优先）。
- `read_answer(main, gid) -> dict | None`。`via` ∈ {终端, 看板, GitHub, 对话, Telegram, auto, 迁移}（库里只存通道名，细节如 `#3` 写进 note / decisions）。
- `record_pr(main, gid, number) -> bool`（`<GID>.pr.json` = {gid, pr, at}，首次生效）：只由控制面在它为该门卡开 PR 时调用（因此 PR 必然晚于门卡）。
- `<GID>.issue.json` = {gid, issue}：发布时由控制面写入。`<GID>.resume`：待接续标记（内容为任务号），交出一次后不再交出。

**门卡含义由控制面决定**
- 批准项固定 A；`then` 只认 `ready`（其他值当作没写，按普通门卡处理）；`then_policy`/`then_rules` 仍只在 A 且非看板时生效。
- 卡上 `pr:` 一律忽略：PR 门卡只看库里的 `<GID>.pr.json`；没有它的卡照常发布成 Issue。MERGED → A，CLOSED → B，via GitHub。
- sync_once 用库里的 issue↔门卡映射，不从 Issue 正文解析门卡号；没有映射的 Issue 跳过。render_issue 去掉卡正文里的 `<!--`。
- 「门卡是否还开着」= 库里没有答案（不看卡上 `status`）；`open_gates` / 接续 / `then` / 任务状态 / apply-gate 都读库。
- `approved_gate(root, tid, kind)` 改读库：root 下仍存在的门卡中，库里快照 `task == tid`、`kind == kind`、`letter == A` 的那张。
  因此 guard_bash（不可逆操作的 ask）与 protect_paths（依赖清单 / locks 的 unlock）自动只认库里的批准，不改 protect_paths.py。

**镜像**：写库成功后控制面写门卡 `status`（approved/rejected 或 answered）、`answer`、`decided_by`（auto 或 human），
decisions.md 追加 `- D-xxx | 日期 | GID | status: answer | via <通道>[ 细节]`。卡上 `resume_pending` 不再使用（接续改看库里的 `.resume`）。

**答案不一致**：卡上 `answer:` 非空或 `status` ∈ {approved, rejected, answered} 而库里没有答案，或卡上答案字母 ≠ 库里字母 →
看板 `/` 把这张卡显示为一个 `<div class="card…">`，含「答案不一致」与门卡号；不接续、不改任务状态；这张卡在看板上仍可答复（库为准）。

**自动决定**：`auto_answer(main, gid) -> bool`：门卡 kind 在 main 的 auto-decide.txt 里（NEVER_AUTO 除外）时按卡上 `recommended`（默认 A）
写库，via=auto；PostToolUse 发布 hook 先调它，成功就不发 Issue。Claude 写 `decided_by: auto` 无效。

**通道与命令**
- 终端：`harness_lib.py answer <GID> <LETTER> [备注]`：退出码 0 = 已记录，1 = 已答复过，2 = 找不到门卡或没有这个选项（卡上无选项时只认 A/B）。
  终端与看板不能起运行：解除阻塞时写 `<GID>.resume`，由下一次 `gate_github.py sync`（`--list-resumable` 列出 `RESUME\t<任务>\t…`）交出一次。
- 看板 POST /answer：库里已有答案 → 409（不看卡上 status）；其余拒绝规则不变。
- `harness_lib.py migrate-answers`：把 v0.1 已答门卡（status approved/rejected/answered 且 answer 非空）导入库，via=迁移；
  开着的卡有数字 `issue:` 时导入映射；不导入 `pr:`；不改门卡、不写 decisions.md；已有答案不覆盖；重复执行结果不变。
- 护栏（guard_bash，同 apply-gate）：Claude 不能运行 `harness_lib.py answer` / `migrate-answers`，也不能在命令里调用
  `record_answer` / `record_pr` / `auto_answer`（grep/rg 搜索除外）。
- strict_settings：`--role task --task T` 时，若库里有 `task == T`、`kind == unlock`、`letter == A` 的答案，则把其快照 `paths` 中
  恰好等于某条 CONTROL_PATHS 的路径从**该 worktree**（root）的 denyWrite 与 Edit/Write 拒绝里去掉；主仓库的条目、其他路径、
  只在卡上写的批准一律不放开。
- human-gate skill 与 rules：Claude 只开卡，不写 `status`/`answer`/`decided_by`；用户在 GitHub、看板或终端（`harness_lib.py answer`）答复。

## 接口约定 v2（第 2 轮挑错后；与 v1 冲突处以此为准）
**门卡快照 meta**：控制面第一次见到一张门卡时（发布 hook、看板 `/` 渲染、`harness_lib.py board`、终端 `answer` / `show`、
gate-sync、`record_answer`）用 O_EXCL 写 `<GID>.meta.json`，之后不再改：
`{gid, task, kind, title, options:[{letter,text}], recommended, paths, then, then_tasks, then_policy, then_rules, at}`。
- `task` 由门卡号推出（`G-T123-4` → `T-123`；`G-GROOM-…` 等 → 空），不读卡上 `task:`；`paths` = 那一刻任务卡的 `unlock:`。
- API：`snapshot_meta(main, gid) -> dict | None`（已有则原样返回）、`read_meta(main, gid) -> dict | None`。
- Issue 正文/标题/标签、看板、终端 `show` 都按 meta 渲染 kind / paths / then；`record_answer`、settle、`apply-gate`、
  看板的「放权类不能在此批准」判断只读 meta。答案 JSON 里的 task/kind/paths 从 meta 复制。
- `harness_lib.py show <GID>`：打印 `kind: …`、`task: …`、`then: …`、`paths: …`、标题与选项（来自 meta），找不到门卡退出 2。
**门卡定位**：`find_gate_card(main, gid)` 只认门卡号所指任务的 worktree（分支 `task/T-xxx-*` 或 `worktree-T-xxx`），否则只认主仓库；
放在别的 worktree 里的同名卡一律无视（record_answer False、终端 answer 退出 2）。
**auto_answer** 只记答案与镜像，永远不执行 `then` / `then_tasks`（只有人的通道才执行）。
**迁移**：审批类（irreversible / unlock / external）按 v0.1 `status` 定字母（approved→A，rejected→B），忽略卡上 answer 字母与 `approve_options`；
不再从卡导入 `issue:` 映射——没有映射的开着的门卡由发布 hook 重新发布（不看卡上 `issue:`）。
**trust_stats / 晨报**：一致率用库里的答案字母与 meta 的 `recommended`，排除 via=auto；晨报「代你决定」列表 = 库里 via=auto 的答案。
**库读不了**（PermissionError 等）：`gate_state(main, gid) -> "open" | "answered" | "unknown"` 返回 unknown；unknown 的卡不在 `open_gates`
里、也不算已答；`board` 输出一行含「状态未知」与门卡号。
**门卡号校验**用 fullmatch（结尾换行等一律拒绝），record_pr / record_issue / record_answer / read_* 同一规则。
**settle 可重放**：settle 完成后写 `<GID>.settled`；gate-sync 对没有 `.settled` 的答案重跑 settle，重复执行不重复写 decisions、不重复接续。
**损坏的答案 JSON**：看板把该门卡列入「答案不一致」（不隐藏），永远不算批准。
**protect_paths**：unlock 放开的路径 = 库中该任务已批准（A）的 `kind: unlock` 门卡 meta 里的 `paths`（`approved_unlock_paths(main, tid)`），
不再读任务卡 `unlock:`；strict_settings 用其中恰为 CONTROL_PATHS 的条目。
**护栏（尽力而为）**：guard_bash 拒绝引用状态目录（`state/harness/`、`.local/state/harness`、`XDG_STATE_HOME`，grep/rg 搜索除外）
或调用 `record_answer` / `auto_answer` 的 Bash 命令。**standard 模式下这不是边界**（Claude 仍可用 Write 工具或别的写法改状态目录），
只有 strict 沙箱是边界；残余风险由 builder 写进 S-002 §7。

## 接口约定 v3（第 3 轮复审后；与 v1/v2 冲突处以此为准）
**终端答复先给你看快照**：`harness_lib.py answer <GID> <LETTER> [备注] [--yes]` 在记录前打印快照：`kind: <kind>`、问题（title）、
每个选项（`A：…`）、unlock 门卡另打印 `paths: <逗号分隔>`。门卡**当前**的 kind / 标题 / 选项文字与快照不同 → 打印差异、
不记录、退出 3；加 `--yes` 则按快照记录（`--yes` 不进备注）。只改了 then / 状态等其他字段不拦。
**快照里存卡片指纹**：meta 增加 `card_sha256`（快照那一刻门卡文件字节的 sha256，64 位小写十六进制）。
**快照何时作废**（精确定义）：只在门卡**没有答案**（库里没有 `<GID>.json`）且没有 `<GID>.pr.json` 时才可能作废；作废条件是
控制面某次「看见」时，该门卡号已解析不到门卡文件（`find_gate_card` 为 None）。「看见」= 发布 hook、看板 `/`、`board`、
`show`、`answer`、gate-sync；其中看板、`board`、gate-sync 会遍历库里所有 meta，检查没有答案的门卡是否还有卡片。
作废 = 删掉 `<GID>.meta.json` 与 `<GID>.issue.json`（旧 Issue 不再映射；卡片再出现时重新快照，由发布 hook 重新发布）。
「门卡号对应的是新文件」= 作废之后再出现的卡片，它得到全新快照。原地改写或替换文件、但控制面从未见到它缺失的，**保留旧快照**
（否则 `sed -i` 之类就能改掉门卡含义）；这类改动由上面的终端检查（退出 3）与各界面只按快照显示来兜住。`card_sha256` 不同时
`answer` / `show` 额外提示「卡片在快照后改过」。
**settle 加锁**：settle 先用 O_EXCL 创建 `<GID>.settling`，失败（已有人在 settle）就直接返回、什么都不写；完成后写 `<GID>.settled`。
`.settling` 存在、没有 `.settled`、且比 `HARNESS_SETTLE_STALE` 秒（默认 600）旧时，gate-sync 可以接手（替换后重跑）。
**信任阶梯**另排除 via=迁移 的答案。
**看板与 board 显示 unlock 路径**：unlock 门卡在看板卡片里于 A 按钮之前列出快照 `paths`；`harness_lib.py board` 的门卡行也列出。
**standard 模式**（N4，只记文档）：Claude 在 standard 模式下调用 `record_answer` 写进库的答案会被下一次 gate-sync settle；
standard 模式不是边界，残余风险写进 S-002 §7。

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 库放哪里 | 仓库外状态目录，所有 worktree 读同一份 | 挑错 F#3 |
| 旧答案 | 迁移，迁移后不报不一致 | 挑错 F#7 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | apply_answer、sync_once、PR 门卡路径、pending_resumes、看板 POST /answer | gate_github.py:236-285,317-415,302-314；serve_cmd.py:424-466 |
| 对外契约 | decisions.md 行格式不变，新增 via 字段值 | - |
| 受影响测试 | test_serve_answer 49 项需改为断言库 | pkg/tests/test_serve_answer.sh |
| 风险 | high | - |

## 4. 修改过程（计划 → 执行日志）
- [x] 1. tester：三个漏洞各写一个失败测试；Claude 改卡里 answer/approve_options/then/pr 不改变结果；迁移测试 — 结果：新增 pkg/tests/test_answers.sh（172 项，现 135 FAIL / 37 PASS，其中 PASS 多为回归护栏）；test_serve_answer.sh 加 11 项查库断言（60 项，现 11 FAIL），原有断言一条未删
- [x] 2. 实现答案库（harness_lib.py：record_answer/record_pr/record_issue/answer_gate/settle_answer/auto_answer/take_resumes）并接入终端、看板、GitHub — 结果：test_serve_answer 60/60
- [x] 3. 门卡语义收紧与迁移（批准=A、then 只认 ready、PR/Issue 映射只认库、open_gates/approved_gate/apply-gate/strict_settings 读库、migrate-answers）— 结果：test_answers 171/172（剩 1 项为测试缺陷，见 §8）、test-harness 215/215
- [ ] 4. skill/规则改写；完整验证 + 对抗审查 — 结果：skill/规则/模板已改，插件已重建；verify 仅剩 §8 的测试缺陷；对抗审查未做

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [ ] A1. 用旧的已合并 PR 号、伪造 Issue 标记、把拒绝项写进 approve_options、then: done，都不会批准或改任务状态（S-002#9） — 证据：
- [ ] A2. Claude 改门卡 answer:/status: 不触发接续，看板标「答案不一致」（S-002#9） — 证据：
- [ ] A3. 终端、看板、GitHub 三个通道写同一库，decisions.md 记 via，重复答复只认第一次（S-002#8） — 证据：
- [ ] A4. 自动决定只由控制面写入（S-002#10） — 证据：
- [ ] A5. 迁移 v0.1 门卡后看板无不一致（S-002#19） — 证据：
- [ ] A6. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：
- [ ] A7. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only main...HEAD` — 证据：

**B. 人工验收（→ 人工门）**
- （无）

## 6. Guardrails（本任务特有）
- decisions.md 行格式保持兼容
- 不删除现有门卡文件

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- （已纳入本任务）standard 模式下 protect_paths.py 用 `H.approved_gate` 读卡上 status 放开 unlock → approved_gate 改读库，见接口约定与 §9。
- （第 2 轮已修）protect_paths 的 unlock 改读 meta 快照里的 paths（approved_unlock_paths）。
- 文档未同步（不在 allowed_paths，留给 T-017）：pkg/scripts/gates.sh 仍按卡上 status 列门卡并提示 `/human-gate G-x: A`；pkg/.claude/rules/harness-guardrails.md §1 仍写「人工门 status: approved」；pkg/README.md 的 decided_by 说明。
- 迁移会把 v0.1 卡上的答案（包括 Claude 曾改过的卡）一次性当真导入：只应在升级时由你执行一次。
- standard 模式下 Claude 的 Write 工具仍可直接写状态目录里的答案文件（strict 下沙箱拒绝）；需 protect_paths 拦状态目录（protect_paths.py 不在本任务 allowed_paths，留待另开任务）。

## 9. 范围变更 / 依赖变更
- 答案库放在 `harness_lib.py`（两种安装方式都有），不新建 `pkg/cli/answers.py`。
- 协调者已批准：`pkg/.claude/hooks/guard_bash.py`、`pkg/scripts/test-harness.sh` 加入 allowed_paths。
- test-harness.sh 需求变更（S-002 #9，批准只认答案库；安全意图不变，均已加反向用例）：
  - 「approved gate -> ask」：改为终端 `answer G-T001-1 A` 后 ask；新增「卡上 status: approved 不算 → deny」。
  - stop_gate 用例：复制门卡时连镜像 answer 一起清空（G-T001-1 由库判定为已答）。
  - 「PR gate attaches to PR / merged PR approves its gate」：改为控制面先 `record_pr(G-T003-5, 7)`，卡上不写 `pr:`。
  - 「gate answered in session closes its issue」→「gate answered elsewhere (terminal) closes its issue」；新增「Claude 把卡写成 answered 不关 Issue」。
  - 新增 v0.1 漏洞 ① 走 gate-sync / harness-loop 同一条 `sync --list-resumable` 的用例（G-T003-8，卡上 `pr: 3` 指向旧的已合并 PR）。
  - 「approved unlock gate opens the manifest」：改为终端批准；新增「卡上 approved 的 unlock 不放开依赖清单」（即 §8 第 1 条，经 approved_gate 读库在本任务内修好）。
  - 「apply-gate writes approved principles」：批准改为写库（`record_answer`），卡保持 open。
  - 全文件 `export XDG_STATE_HOME="$T/state"`，不碰真实状态目录。
- builder：`plugins/harness/**` 加入 allowed_paths——`bash pkg/plugin/build.sh plugins/harness` 重新生成的插件副本（test_plugin_install 要求它与 pkg 一致），不手改。
- builder：看板上「答案不一致」的卡单独列出，只显示门卡号、任务、库里的答案与文件路径（不显示卡上 Claude 可写的标题），不计入待审阅分钟数——兼容既有 test_serve.sh（v0.1 `status: answered` 的卡不出现标题、不计时）。
- builder（第 2 轮）：`docs/specs/S-002-hard-boundaries.md` 加入 allowed_paths——协调者要求在 §7 补一条残余风险（standard 模式下答案库只靠护栏，strict 才是边界）。
- builder（第 2 轮）：auto_answer 要求快照 kind 与卡上当前 kind 都在 auto-decide.txt 且都不属 NEVER_AUTO——Claude 改卡只能让它改为问人，不能反过来（test_answers「issue title renders the snapshotted kind」需要）。
- builder（第 2 轮）：trust_stats 统计本 checkout 里（且归属正确）的门卡在库里的答案——保持 v0.1 的统计范围（test-harness「ui 8/8」）。
- builder：then_policy / then_rules 只在经 GitHub 或终端批准时生效；看板、auto、迁移、对话不生效（auto 生效会让已放权类别的门卡给自己再放权）。

- 第 2 轮（协调者批准）：`pkg/.claude/hooks/protect_paths.py` 加入 allowed_paths（unlock 路径改读库中 meta）。
- 第 2 轮需求变更（tester）：
  - test_answers.sh：迁移不再导入卡上 `issue:`（原「open card's issue mapping imported」改为断言不导入 + 重新发布）；G-T106-4 改为 design（避免被 auto 决定）；
    T-125 / T-126 的卡移到主仓库（v2：别的 worktree 里的卡不认）。
  - test-harness.sh：信任阶梯 G-TR-* / G-TI-* 的答案改为写库；晨报的自动决定 G-AU-1 改由 `auto_answer` 写库；各加 Claude 伪造卡的反向用例；
    依赖清单 unlock 增加「批准后再加进 unlock: 的路径不放开」。

- 第 3 轮需求变更（tester）：test_answers.sh 的「v2: terminal answer after relabel exits 0」改为退出 3、再用 `--yes` 按快照记录（v3：终端答复先核对快照）。

## 10. Verifier 结论
- 结论：PENDING   # PASS | FAIL
- 说明：

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 把写库、镜像、接续集中到 harness_lib（插件模式也有），gate_github/serve 只调用 | harness_lib 答案库 + gate_github sync 重写 + serve POST/看板 + guard_bash + strict_settings | test_answers 171/172、serve_answer 60/60、test-harness 215/215 |
| 2 | 既有 test_serve「answered gates hidden / 19 分钟（4 项）」与「不一致要显示」冲突，可把不一致卡单列、不显示卡标题、不计时 | serve_cmd view_decide/load_minutes | test_serve 20/20 |
| 3 | 「... no policy added」失败是测试本身的问题（文件不存在时 grep 无输出） | 不改测试，记 §8 | 仍 1 FAIL（tester 已在 283e564 修正） |
| 4 | 第 2 轮：含义改由首见快照 meta 决定；门卡只认所属 worktree / 主仓库；库读不了=unknown；settle 可重放 | harness_lib 答案库 v2、gate_github 渲染/发布/同步、serve 读 meta、protect_paths 读 meta paths、guard 状态目录 | test_answers 234/235（auto 被卡上改标签反向利用的用例） |
| 5 | 卡上 kind 改成 NEVER_AUTO 时 auto 仍按快照放行，与「发布按快照 kind 开 Issue」用例冲突；改为两者都允许才 auto（只会更保守） | auto_answer | 235/235 |
| 6 | trust 改为全库统计后把别的 worktree 的门卡也算进来（ui 9/10） | trust_stats 只数本 checkout 的门卡 | test-harness 218/218 |
| 7 | 第 3 轮：终端 answer 先打印快照、含义不符退出 3（--yes 按快照）；没答的门卡被看见缺失时作废快照与映射；settle 用 O_EXCL .settling 加锁、gate-sync 接手过期锁；trust 排除迁移；看板 / board 列 unlock 路径 | harness_lib（card_meaning/meaning_diff/retire_*/_claim_settle）、gate_github、serve_cmd、S-002 §7 | test_answers 268/268、test-harness 218/218 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查（另开挑错会话专门找毛病 → 裁判只留成立的；risk medium/high 必填，low 建议）
<!-- 挑错角度：python3 .claude/hooks/harness_lib.py critics <risk> verify -->
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
