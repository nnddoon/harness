---
id: T-024
title: 0.2.2：控制面按基准任务卡检查改动范围
status: review
priority: P0
risk: high
size: M
source: human
spec: S-003
test_owner: tester
branch: task/T-024-scope-check
worktree: .claude/worktrees/T-024
session: auto
depends_on: [T-023]
context_files: [docs/feedback/s003-review-r1.md, docs/feedback/best-practices-review.md]
allowed_paths: [pkg/.claude/hooks/harness_lib.py, pkg/.claude/hooks/protect_paths.py, pkg/.claude/hooks/gate_github.py, pkg/scripts/harness-loop.sh, pkg/scripts/new-task.sh, pkg/cli/doctor_cmd.py, pkg/tests/test_scope.sh, pkg/tests/test_control_paths.sh, pkg/tests/test_lifecycle.sh, pkg/scripts/test-harness.sh, pkg/plugin/RELEASED.json, pkg/README.md, plugins/harness/**, docs/feedback/best-practices-review.md]
locked_paths: []
unlock: []
gates: []
auto_ok: no
---

# T-024 0.2.2：控制面按基准任务卡检查改动范围

## 1. 背景与目标
外部审查（`docs/feedback/best-practices-review.md` 三-1、三-2）指出：R-1 的根源是「列举输入」，T-023 的配置文件清单会一直补不完；更大的洞是 `allowed_paths` 只由会话内的编辑 hook（protect_paths 规则 5）检查——Bash 写文件不受管，而且任务自己可以改任务卡的 `allowed_paths`（§9 写一句就扩大范围），等于执行者给自己定范围。用户决定把「按基准任务卡检查改动范围」放进 0.2.2（2026-11-15，选 A）。

目标：任务分支改动的每个文件都必须落在**基准提交（main）上那张任务卡**的 `allowed_paths` 内（加上任务自己的记录文件）；范围外的改动由控制面拦下，走现有 ctl 门卡流程，人批准后才可合并。分支里对自己任务卡范围字段的修改一律不算数。T-023 的 JS 配置清单保留，作为 strict denyWrite 的早期提醒。

## 2. 范围
**做：**
- `control_diff(..., task=...)`：任务卡在基准提交里有非空 `allowed_paths` 时，分支 diff 里不匹配它、也不是 `own_task_paths(task)` 的文件 → 计入命中（与 CONTROL_PATHS 命中同一出口，所以 harness-loop finish、gate_github 发布 / 合并检查自动覆盖）。范围只取基准提交的卡（不取分支卡；人在 main 上改卡并提交即为扩大范围）。
- 已批准的 ctl 门卡：快照里列出的范围外文件，在同一提交内容下放行（与 `approved_unlock_paths` 同一机制；文件之后再改则重新命中）。
- 基准卡没有 `allowed_paths` 或为空 → 不做范围检查（退回现有列举），doctor 对 ready/claimed/in_progress 的这类任务给一行提醒。
- protect_paths 规则 5：`allowed_paths` 以主仓库任务卡为准（取不到时才用 worktree 卡）；worktree 里修改本任务卡 frontmatter 的 `allowed_paths` / `locked_paths` / `unlock` / `auto_ok` / `risk` 一律拒绝，提示在 §9 写提议并开门卡。
- ctl 门卡正文区分「控制文件」与「超出任务范围」两类命中，范围外的列出文件并说明批准的含义。
- 版本仍为 0.2.2（未发布），重建插件与 RELEASED.json；README 0.2.2 一节加一行。

**不做（明确排除）：**
- 不做「测试数不能变少」的不变量（→ S-004）。
- 不做风险下限按路径计算（→ S-004），只是禁止任务自己改 risk。
- 不改 Python / JS 入口列举逻辑。

## 接口约定（tester 2026-11-15；测试：`pkg/tests/test_scope.sh`，调度器部分在 `pkg/scripts/test-harness.sh`「scope (T-024)」一节）

### 1. 范围从哪来：`task_scope(root, ref, tid) -> list | None`（harness_lib）
- 读提交 `ref` 里的任务卡：与 `_commit_card_locks` 同一选法（`git ls-tree ref -- .harness/tasks/`，取排序后第一个 `.harness/tasks/<tid>-*.md`；只叫 `<tid>.md` 的卡不认）。建议把两者合成一个 `_commit_card_fm(root, ref, tid) -> dict` 共用。
- 返回 `None`（= 不做范围检查）：`tid` 为空 / 不是 `T-\d{3,}`、卡不存在、frontmatter 没有 `allowed_paths`、值是 `[]` 或空串。
- 否则：标量写法 `allowed_paths: src/**` 等同 `[src/**]`；每项按 `_good_lock` 规范化（`./` 去掉，`X/` → `X/**`，绝对路径 / 含 `..` / 非字符串的项丢掉）。原值非空但规范化后一项不剩 → 返回 `[]`（照样检查：除自己的记录文件外全部算范围外，宁可多拦）。
- 只认 `ref` 里**已提交**的卡：分支卡、worktree 卡、主仓库工作区里没提交的改动都不算（人在 main 上改卡并提交 = 扩大范围）。

### 2. `control_diff` 怎么算范围外（命中出口不变）
新增 `control_diff_categories(root, base, branch, task="", card_ref="", scope_base="") -> {"control": [...], "scope": [...]}`（两项各自排序、互不重复）；`control_diff(root, base, branch, task="", card_ref="", scope_base="")` 返回 `sorted(control ∪ scope)`，签名只加关键字参数，现有调用方与断言不变。
- `control` = 现在 control_diff 的全部命中（CONTROL_GLOBS、上级目录、验证入口、locked_paths），算法一字不改。
- `scope` 只在 `task` 非空且 `task_scope(root, card_ref or base, task)` 不是 `None` 时计算；`task` 为空（CLI 不带 `--task`、非任务分支、`new-task.sh` 的基线检查、整合分支推送检查）一律不查范围。
- 范围 diff：`git diff --name-only --no-renames -z <S>...<branch>`，`S = scope_base`；没给时按顺序取：① 环境变量 `HARNESS_BASE`（不以 `-` 开头、`rev-parse --verify <值>^{commit}` 成功）；② `HARNESS_INTEGRATION`（形如 `integration/…` 且是本地分支）；③ `base`。用途：夜间模式任务从整合分支开出（调度器导出两者 = 整合分支），`new-task.sh` 用 `HARNESS_BASE=<基线>` 开 worktree 时基线里别的改动不算本任务的（现有用例 `new-task: clean base still works` 依赖这一点）；finish、`new-task.sh` 都继承调度器 / 人设的环境，`new-task.sh` 不用改。这两个变量只由人或调度器设置，Claude 的会话改不了控制面进程的环境。改名两边都算、删除也算（`--no-renames`，与 control 相同）。
- 一个文件 `p`（来自范围 diff）算范围外，当且仅当以下都不成立：
  1. `p` 已在 `control` 里（同一文件只归一类，控制文件优先）；
  2. `is_own_path(task, p)`（原样路径，不折叠；ctl 门卡 `.harness/gates/G-Txxx-ctl*` 及其附件**不**豁免）；
  3. `matches_any(fold(p), [fold(g) for g in 范围 ∪ approved_unlock_paths(main, task)])`，`fold` = NFC + casefold（与 control_diff 其余部分相同）。已批准的 unlock 门卡路径本来就是人允许本任务改的（保持 test_lifecycle 的 LICENSE 用例成立）；
  4. 已批准的 ctl 门卡放行了它在 `branch` 里的这一版内容（见 §3）。
- `.harness/` 下的记录：任务自己的卡 / 交接包 / 门卡（own_task_paths）照旧豁免；`backlog.md`、`locks.txt`、`decisions.md`、`.harness/logs/**` 本来就是控制文件（归 control）；`STATUS.md`、`reports/**` 只在主仓库写、不上任务分支。调度器在任务分支上只提交本任务的卡（`harness: claim`）和任务自己的记录，所以正常流程不会被范围检查拦下。别的任务的卡、`.harness/sources.md`、`.harness/test-paths.txt` 等不豁免。
- `plugins/harness/**` 等打包产物就是普通路径，按 allowed_paths 判断。
- 已知限制（写进 README 一行即可）：分支基于还没合进 main 的别的任务分支（手动堆叠，非夜间模式）时，依赖任务的文件对 `main` 也算范围外，直到依赖合进 main 后 rebase / merge main。

### 3. 已批准的 ctl 门卡放行范围外文件（绑定内容）
- `record_ctl_scope(main, gid, tid, commit, files) -> bool`：控制面进程内调用（**不加 CLI**，同 `open_task_pr` 的做法）。校验 `is_ctl_gid(gid)`、`task_of_gid(gid) == tid`、`commit` 是 40/64 位十六进制且在主仓库里是提交；对每个文件取它在 `commit` 里的条目 `"<mode> <oid>"`（`git ls-tree -z --full-tree`，literal pathspec；不存在 = 删除 = `""`），写 `<答案库>/<gid>.scope.json` = `{"gid","task","commit","files": {原样路径: 条目},"at","at_ns"}`，`_create_json`（O_EXCL，已存在不覆盖，返回 False）。`read_ctl_scope(main, gid) -> dict | None`（`gid` 字段不符 → None）。
- `next_ctl_gid` 另外跳过已有 `<gid>.scope.json` 的号（其余规则不变）。
- `approved_scope(main, tid) -> set[(fold(path), 条目)]`：对 `_ctl_gids(main, tid)` 里每个 gid，同时满足才收：答案库答复 `letter == "A"`、非 `_bad`、`task == tid`；`read_meta(...)["task"] == tid`；`read_ctl_scope` 存在、`task == tid`；`rec_ns(scope) <= rec_ns(answer)`（记录早于答复）。答复 B/C、未答复、没有 scope 记录 → 什么都不放行。
- §2 第 4 条：`(fold(p), p 在 branch 里的条目)` 在 `approved_scope` 里 → 不算命中。之后再改这个文件（内容、权限位、删除、恢复）→ 条目不同 → 重新命中，`ctl_block` 用下一个号 `G-Txxx-ctl-<n>`。
- 只放行 `scope` 类；`control` 类（含 locked_paths）不因 ctl 批准放行（现状：批准 ctl = 人手工合并）。ctl 批准仍不触发 `release_blocked`（T-021 规则不变）。

### 4. CLI 与调度器
- `harness_lib.py control-diff [<base>] <branch> [--root DIR] [--task T-xxx] [--card-ref REF] [--scope-base REF] [--categories]`：默认输出不变（每行一个路径）；`--categories` 时每行 `control\t<路径>` 或 `scope\t<路径>`，先全部 control 再全部 scope，各自排序。退出码不变（0 无命中 / 1 有命中 / 2 出错）；`--card-ref` / `--scope-base` 缺值或以 `-` 开头 → 2。
- `harness-loop.sh`：
  - finish：`control-diff main "$SHA" --root "$ROOT" --task "$TID" --categories`；integrate：`control-diff "$pre" "$merged" --root "$ROOT" --task "$TID" --card-ref main --categories`（范围卡永远取 main）；第 385 行整合分支推送检查不带 `--task`，不变。
  - `ctl_block <TID> <命中> <分支> [<提交>]`：命中按行解析，`scope\t` → 范围外、`control\t` → 控制文件、其他行（出错信息、找不到分支）→ 控制文件原样。控制台：有控制文件时照旧 `✗ <TID> 改到控制路径：a, b`；有范围外时另一行 `✗ <TID> 超出任务范围：x, y`。
  - 门卡：标题按类别 `改到控制路径` / `超出任务范围` / `改到控制路径、超出任务范围`（`# <GID> <TID> …：批准这些改动吗？`）；`## 改到的控制路径` 只在有控制文件时出现；有范围外时加 `## 超出任务范围的文件`（列出文件），下面说明：这些文件不在 main 上任务卡的 allowed_paths 内（分支里改任务卡不算数）；批准 = 只放行这些文件在提交 `<SHA 前 12 位>` 里的内容，之后再改其中任何一个会重新拦下；要长期扩大范围，在 main 上改任务卡 allowed_paths 并提交。frontmatter 加 `scope_commit: <SHA>`（仅供阅读）。其余字段、选项 A/B、回复格式不变。
  - 有范围外文件且有提交时，`ctl_block` 写完门卡后进程内调用 `record_ctl_scope(ROOT, GID, TID, SHA, 范围外文件)`（finish 传 `$SHA`，integrate 传任务提交 `$SHA`）。
- `gate_github.py`：`push_assets` / `push_assets_ctl` 继续调 `control_diff(main, "main", …, task=…)`，自动带上范围检查（范围外 → 不推）；不需要改代码，测试覆盖。
- `new-task.sh`（不在 allowed_paths）：复用已有分支时的 `control-diff … --task` 自动带上范围检查；拒绝提示里的「改到控制路径或本任务的 locked_paths」措辞暂不改（§8）。

### 5. protect_paths 规则 5
- 范围卡：`mc = main_checkout(cwd)`；`task_card_path(mc, tid)` 存在 → 它的 `allowed_paths`（主仓库工作区，未提交的也算——hook 只是提前提醒，控制面只认提交）；主仓库没有这张卡 → 用 worktree 卡（现状）。主仓库卡存在但 allowed_paths 为空 → 规则 5 不限制。规则 7 的 `test_owner` 仍读 worktree 卡（不在本任务范围，§8）。
- 新规则 5a，放在 `BOOKKEEPING_OK` 提前放行**之前**：当前是任务会话（linked worktree，或当前分支名含任务号；默认分支上的控制塔 / task-align 会话不受限）、目标是本任务自己的卡（`.harness/tasks/<tid>.md` 或 `<tid>-*.md`），且这次写入会改变 frontmatter 里 `allowed_paths` / `locked_paths` / `unlock` / `auto_ok` / `risk` 任一字段 → deny。比较：旧 = 当前 checkout 里这张卡的 frontmatter（文件不存在 → 主仓库卡的）；新 = Write 的 `content`，或 Edit 在旧文本上做 `old_string → new_string`（`replace_all` 全换，否则只换第一处；找不到 `old_string` → 不判，放行给 Edit 自己报错）。按 `frontmatter_of` 解析后的值比较，缺字段与空值不等同于有值。改卡的其他部分（status、§4、§7、§9 等）照常允许。
- 拒绝信息（中文，须含字段名、「9. 范围变更」与 `/human-gate`）：「不能在任务分支里改本任务卡的范围字段（<字段>）：范围以 main 上的任务卡为准，分支里改了也不算数。需要扩大范围：在任务卡「9. 范围变更」写明要加的路径和原因，再开 /human-gate（unlock 或 ambiguity），由人在 main 上改卡并提交。」
- Bash：protect_paths 只挂 Edit|Write|NotebookEdit，不解析 Bash；guard_bash 不在本任务 allowed_paths。Bash 改卡（sed -i、heredoc）不拦，保证来自控制面只认基准卡（A2）。是否给 guard_bash 的 heredoc 解析加同样的检查见 §9。

### 6. doctor
- `harness doctor` 新段 `## 任务范围`，只在有内容时出现：主仓库 backlog 里状态为 `ready` / `claimed` / `in_progress` 的任务，`task_scope(main, <默认分支>, tid)` 为 `None` → 一行 `<tid>：任务卡没写 allowed_paths，控制面不检查它改动的范围（只拦控制文件和 locked_paths）；在 main 上给任务卡补上 allowed_paths 并提交`。其他状态、有 allowed_paths 的任务不报；默认分支取不到 → 本段报 `检查失败：…` 不挂。

### 7. 不能变的行为
- `control_diff` 不带 task、或基准卡无 allowed_paths 时，输出与现在逐字相同；`control` 类算法（含 T-023 JS 入口、package.json 只读基准、locked_paths 三处并集、approved unlock 放行、own 豁免）不变。
- `stray_entries`、`release_blocked` / `settle_answer`（ctl 与 merge 答复不参与放行）、`next_ctl_gid` 现有编号规则、`snapshot_meta`、门卡 A/B 选项与回复格式不变。
- 已有测试一个不改；与新规则冲突的写进 §9（见下）。

## 接口约定 v2（tester 2026-11-15，安全挑错第 1 轮后；测试：`pkg/tests/test_scope.sh`「v2」一节，调度器部分在 `pkg/scripts/test-harness.sh`「scope v2 (T-024)」一节；v1 未提到的照旧）

### F1 ctl 门卡不是 unlock 门卡（必修）
- `_gate_unlock_paths(main, card, gid, kind)`：`is_ctl_gid(gid)` → 恒为 `[]`（不读门卡 `paths:`，也不回退到任务卡的 `unlock:`）。新快照的 ctl 门卡 `meta.paths == []`。
- `approved_unlock_paths(main, tid)` 跳过 `is_ctl_gid(gid)` 的答复（旧快照里已带 paths 的 ctl meta 也不算）；`unlocked_paths`、control_diff 的 `free`（locked_paths 放行）、范围检查的「已批准 unlock 路径」都经由它，自动一致。
- ctl 门卡批准**只**通过 v1 §3 的内容绑定记录（`approved_scope`）放行范围外文件；控制文件、locked_paths 命中永远不因 ctl 批准放行；strict 启动器不因 ctl 批准放开任何 denyWrite。

### F2 自动提交不改范围、ctl 未答复不重派（必修）
- 新增 `stage_bookkeeping(root, paths) -> list[str]`（harness_lib）与 CLI `harness_lib.py stage-bookkeeping <路径>…`（警告逐行打到 **stderr**，退出码 0；git 出错 → 2）：对 `paths` 做 `git add`，然后对每个暂存区里与 HEAD 不同的 `.harness/tasks/*.md`：
  - HEAD 里有这张卡、暂存版本的 `allowed_paths` / `locked_paths` / `unlock` / `auto_ok` / `risk` 与 HEAD 不同 → 暂存区换成「工作区文本，但这五个字段的行恢复成 HEAD 的原行（HEAD 没有的字段删掉）」；工作区不动（改动留给人提交）。其他字段（status、owner…）和正文照常提交。
  - HEAD 里有、工作区删掉或改名 → 删除不暂存（`git restore --staged` 回 HEAD 版本）。
  - 每张被挡的卡一行警告：`⚠ <TID> 的任务卡范围字段（<字段，逗号分隔>）在主仓库被改动，控制面不会自动提交：范围只认人提交的版本；确认后请在 main 上自己提交`（删除时字段写「整张卡被删除」）。
  - HEAD 里没有的新卡照常提交（已知限制：/replan 拆出、/backlog-groom 新建的卡由 agent 写好范围，见 §8 → S-004；README「已知限制」加一行）。
- 用它的地方：`harness-loop.sh` 的 `commit_bookkeeping`（`git add` 换成 `stage-bookkeeping`，提交照旧只在暂存区有改动时做）、`new-task.sh` 的认领提交（**需要把 `pkg/scripts/new-task.sh` 及其插件副本加进 allowed_paths，见 §9**）。
- `has_open_ctl(main, tid) -> bool`：`_ctl_gids(main, tid)` 里有门卡在主仓库、`gate_state == "open"` 的 → True。`next_ready` 与 `pick_batch` 跳过这样的任务（不改 `claimable`，晨报「任务卡未就绪」不列它）。答复（A/B 均可）之后照常可派发。

### F3 自己的卡只认基准里那一张（低成本，包含）
- 范围检查里的 own 豁免：`.harness/tasks/` 下只豁免 `_commit_card_fm` 在 `card_ref or base` 里选中的那个文件名（原样路径比较）；同任务号的其他文件（`.harness/tasks/<tid>.md`、`<tid>-0.md` 等诱饵）→ 范围外命中。交接包、门卡及附件的豁免不变；`is_own_path` 本身（locked_paths 用）不变。

### D1 gate_github 定时任务里的范围基（回归，必修）
- 新增 `record_task_base(main, tid, commit) -> bool`（控制面进程内调用，**不加 CLI**）：校验 `tid`、`commit` 是主仓库里的提交，写 `state_dir(main)/task-base/<tid>.json` = `{"task","commit","at","at_ns"}`（覆盖写，原子替换）；`task_base(main, tid) -> str`：记录的提交（读不到 / 不是提交 → `""`）。
- `harness-loop.sh`：`new-task.sh "$TID"` 成功后、启动会话前，记录 `git merge-base <基线> refs/heads/<任务分支>`；基线 = 夜间模式 `refs/heads/$IBR`，否则 `main`。
- `gate_github.push_assets_ctl` 与 `push_assets`：`control_diff(main, "main", sha, task=tid, scope_base=b)`，`b = H.task_base(main, tid)` 且它是 `sha` 的祖先（`merge-base --is-ancestor`）时用它，否则 `""`（落回 `HARNESS_BASE` / `HARNESS_INTEGRATION` / main，**失败即拦**：基线不明 → 别的任务的文件算范围外 → 不推）。
- finish / integrate 仍按 v1（环境变量 + `--card-ref main`）。

### v2 不能变的行为
- v1 §7 全部；unlock 门卡（非 ctl）的批准语义、`paths:` 快照、T-010 用例不变；`claimable` 不变。

## 接口约定 v3（tester 2026-11-16，安全挑错第 2 轮后；测试：`pkg/tests/test_scope.sh`「v3」一节，new-task / harness-loop 部分在 `pkg/scripts/test-harness.sh`「scope v3 (T-024)」一节；v1/v2 未提到的照旧）

### N1 记录提交用临时索引（必修）
- 新增 `commit_bookkeeping(root, paths, message) -> (sha, warnings)`（harness_lib）与 CLI `harness_lib.py commit-bookkeeping -m <信息> <路径>…`：提交了就在 stdout 打印新提交的 SHA（没有可提交的打印空），警告逐行打到 stderr；退出码 0，git 出错 / HEAD 不在分支上 / 提交期间 HEAD 被换掉 → 2，什么都不提交。
- 做法：临时索引文件（`GIT_INDEX_FILE`，建在 `.git` 之外的临时目录、用完删除）先 `read-tree HEAD`，只对 `paths` 做 `add -A`，在这个索引上按 v2 F2 + 下面 N2/N3 的规则挡回范围改动，`write-tree`；树与 `HEAD^{tree}` 相同 → 不提交；否则 `commit-tree -p HEAD`，`update-ref HEAD <新> <旧>`（带旧值，原子）。
- 提交后用户真实索引：本次提交改到的路径，索引条目换成新 HEAD 的；**其他条目（用户自己暂存的文件，包括 `.github/**` 等控制路径）原样保持暂存**；工作区一个字节不动（被挡回的改动仍在工作区）。提交里只有 `paths` 下的文件。
- 使用方：`new-task.sh` 的认领提交（去掉 git add + 快路径 + `git commit`，改成 `commit-bookkeeping -m "harness: claim <TID>" .harness`），`harness-loop.sh` 的 `commit_bookkeeping`（`commit-bookkeeping -m "harness: $1" .harness .claude/rules/lessons.md`）。两处都不再调用会提交整个真实索引的 `git commit`。
- `stage-bookkeeping` CLI 保留（作用于当前 `GIT_INDEX_FILE` 指向的索引），v2 用例不变。

### N2 没有快路径，坏掉的 frontmatter 也挡回（必修）
- 认领 / 记录提交一律逐卡比较范围字段，不认「只动了 status 行」的文本捷径。
- HEAD 里有的卡，新版本 frontmatter 解析不出来（不以 `---` 开头、没有结束的 `---` 等，`frontmatter_of` 为 `{}`），或 HEAD 有的范围字段新版本里没了 → 当作范围字段改动，整张卡挡回（索引保持 HEAD 版本），警告点名任务号。
- 挡回的改动留在工作区；之后任何一次认领 / 记录提交都按同一规则再挡，永远不会被后来的提交顺带提交。

### N3 同一任务号只能有一张卡（必修）
- 记录提交里新增（A，含改名产生的 A）`.harness/tasks/<tid>.md` 或 `<tid>-*.md`，而 HEAD 已有这个任务号的任意一张卡 → 不提交这个新文件，警告 `⚠ <TID> 新增了第二张任务卡 <路径>，控制面不会自动提交：同一任务只认一张卡，请人在 main 上处理`。改名（D + A）两边都挡（旧卡保留、新名不加）。HEAD 没有该任务号的卡的新卡照常提交（v2 已知限制）。
- 范围解析失败即拦：某个版本（`card_ref or base`）里同一任务号的卡文件（`<tid>.md` 与 `<tid>-*.md` 合计）多于一个 → `task_scope` 抛 `LaunchError(2, "<ref> 里 <TID> 有不止一张任务卡（<路径, 路径>）：范围无法确定，请人在 main 上删掉多余的卡")`；`control-diff --task` 因此退出 2（finish / integrate / new-task 照「失败即命中」拦下，gate_github 不推）；不带 `--task` 不受影响。locked_paths 取这些卡的并集（多锁无害）。
- doctor「任务范围」：这类任务一行 `<TID>：<默认分支> 上有不止一张任务卡（…）：范围无法确定`。

### v3 不能变的行为
- v1 §7、v2 全部；记录提交的提交信息（`harness: claim <TID>`、`harness: <事由>`）不变；没有 `.harness` 改动时不产生提交。

## 3. 需求对齐与影响分析
**对齐记录**
| 问题 | 结论 | 来源（用户原话 / 决策编号 / 推断） |
|---|---|---|
| 放进 0.2.2 还是 S-004 | 0.2.2，单开 T-024 | 用户 2026-11-15 选 A |
| 范围以哪张卡为准 | 基准提交（main）上的卡 | 推断（执行者不给自己定范围） |
| 扩大范围怎么批 | ctl 门卡（现有流程）或人在 main 上改卡 | 推断 |

**影响分析**
| 项目 | 结果 | 证据（命令 / 文件:行） |
|---|---|---|
| 直接改动 | control_diff、protect_paths 规则 5、ctl 门卡正文、doctor | `harness_lib.py` control_diff；`protect_paths.py` 规则 5 |
| 调用方 | harness-loop finish（ctl_block）、gate_github 发布与合并检查 | `harness-loop.sh` ctl_block / control-diff；`gate_github.py` control_diff |
| 风险 | high（控制面；误拦会卡住所有任务，漏拦即范围失效） | - |

## 4. 修改过程（计划 → 执行日志）
- [x] 1. tester — 结果：接口约定写入本卡；新增 `pkg/tests/test_scope.sh`（121 条，当前 84 条失败）与 test-harness.sh「scope (T-024)」一节（35 条，当前 26 条失败；全文件 353/379）；夹具按 §9 调整后，test_lifecycle 190/192（2 条 T-202 断言需新 API）；其余已有用例全过。
- [x] 2. 实现 — 结果：harness_lib（`_commit_card_fm` / `task_scope` / `control_diff_categories` / `record_ctl_scope` / `read_ctl_scope` / `approved_scope`，CLI `--card-ref` `--scope-base` `--categories`，`next_ctl_gid` 跳过 scope 记录）、protect_paths 规则 5 / 5a、harness-loop ctl_block / finish / integrate、doctor「任务范围」、README 一行；插件与 RELEASED.json 重建（0.2.2）。test_scope 121/121、test-harness 379/379、test_lifecycle 192/192，其余 pkg/tests 全 N/N。偏差：integrate 另传 `--scope-base "$pre"`（整合时 HARNESS_BASE 指向的整合分支已含合并结果，范围 diff 会是空的）。 第 2 轮（接口约定 v2）：F1 ctl 门卡不给 unlock 路径；F2 `stage_bookkeeping` / `stage-bookkeeping`、`has_open_ctl`（next_ready / pick_batch 跳过）、commit_bookkeeping 与 new-task 认领提交改用它（new-task 只改 status 行时走 git add 快路径，开销与 288fed7 持平）；F3 只豁免基准卡文件名；D1 `record_task_base` / `task_base`，调度器在本批会话都启动后记 merge-base，gate_github 用它（须是祖先）。test_scope 158/158、test-harness 394/394。 第 3 轮（v3）：`commit_bookkeeping` / CLI `commit-bookkeeping`（临时索引 read-tree → stage_bookkeeping → write-tree → commit-tree → update-ref 带旧值，再只把本次提交改到的路径在用户索引里换成新 HEAD 的）；new-task 去掉快路径、harness-loop 记账都改用它；stage_bookkeeping 挡回坏掉的 frontmatter / 删掉的范围字段 / 同号第二张卡；`_commit_cards`：同号多张卡时 task_scope 抛错、locked_paths 取并集；doctor 多卡一行。test_scope 188/188、test-harness 408/408（parallel 重叠余量约 0.6s）。
- [ ] 3. 挑错 — 结果：
- [ ] 4. verifier — 结果：

## 5. 验收标准
**A. 机器验收（verifier 子代理逐条核对）**
- [x] A1. 分支改了基准卡 `allowed_paths` 外的文件（经 Edit 或 Bash 均可）→ control_diff 命中，finish 走 ctl 门卡、不合并 — 证据：见 §10 verifier 结论
- [x] A2. 分支自己扩大任务卡 `allowed_paths` 不起作用；人在 main 上扩大并提交后不再命中 — 证据：见 §10 verifier 结论
- [x] A3. 批准的 ctl 门卡放行快照内的范围外文件；文件再改后重新命中；被拒则保持拦下 — 证据：见 §10 verifier 结论
- [x] A4. R-1 复现（只改 `jest.config.js`，卡的 allowed_paths 为 `src/**`）在没有 JS 清单的情况下也被范围检查拦下 — 证据：见 §10 verifier 结论
- [x] A5. protect_paths 以主仓库卡为准，worktree 里改范围字段被拒 — 证据：见 §10 verifier 结论
- [x] A6. 无 allowed_paths 的卡不做范围检查，doctor 提醒 — 证据：见 §10 verifier 结论
- [x] A7. 已有测试全部通过，未删除/跳过任何测试 — 验证：`bash .harness/verify.sh` — 证据：见 §10 verifier 结论
- [x] A8. 仅修改了 allowed_paths 内的文件 — 验证：`git diff --name-only task/T-023-js-runner-configs...HEAD` — 证据：见 §10 verifier 结论**B. 人工验收（→ 人工门）**
- （无）

## 6. Guardrails（本任务特有）
- 范围只信基准提交；分支和 worktree 里的卡只当数据。
- 任务自己的记录文件（own_task_paths）永远放行，但 ctl 门卡及其附件除外（沿用 is_own_path）。
- 拦下时信息要能直接用：列出文件、说明怎么批。

## 7. 当前进展（中断/换对话时更新）
- 最后更新：
- 做到哪：
- 下一步：
- 卡住的点：

## 8. 发现的问题（不在本任务范围，收尾时进 backlog 提议区）
- tester：`permission_allow.py` 自动放行 Edit 用的是 worktree 卡的 allowed_paths（protect_paths 先拦，影响有限）；规则 7 的 `test_owner` 也读 worktree 卡，任务能自己把 tester 拆分关掉（`test_owner: any`），与「执行者不给自己定规则」同类。
- tester：`new-task.sh` 复用分支被范围拦下时提示仍写「改到控制路径或本任务的 locked_paths」。
- tester：夜间模式下范围 diff 以整合分支为基；能改 `refs/heads/integration/*` 的会话可以把自己的改动藏进基线（与现有 integrate() 的 locked_paths 检查同一信任假设），最终 integration → main 仍由人审。

- tester → S-004：`guard_bash.py` 的 cat/tee heredoc 解析写本任务卡时同样比较范围字段（与 answer_in_gate_doc 同法）；`new-task.sh` 显式传 `--scope-base "$BASE_SHA"`，不靠 `HARNESS_BASE` 环境变量。两者都不影响控制面的保证（只认基准卡）。

- tester → S-004（F2 已知限制）：agent 新建的任务卡（/replan 拆出、/backlog-groom 提议）由 agent 自己写 allowed_paths / risk / auto_ok，控制面会照常提交；需要「新卡范围由人确认」的机制。

- tester → S-004：每次派发（认领提交 + 记录基线 + 记录提交）约 1.4 秒，开销可以再降（例如只在 `.harness/tasks/` 有改动时才逐卡比较）。
- tester：test-harness 偶发 `v3 receivepack: tamper actually happened (fixture sanity)` 失败（3 次里 1 次，与 T-024 改动无关，像是 T-091 派发时机的夹具竞态），值得单独查。

- `v3 receivepack: tamper actually happened`：2026-11-16 一次性失败，60+ 次未复现，非 T-024 引起；夹具已加标记与日志输出，再出现时看 ctl9.out

## 9. 范围变更 / 依赖变更
- tester 2026-11-15：**已有测试与新规则冲突（未改动，待人决定改夹具还是改约定）**。用一份按「接口约定」写的草稿实现（只在 /tmp，未提交）跑全部套件得出：
  1. `pkg/scripts/test-harness.sh`「tester/builder split」一节（4 条：`tester edits tests`、`test_owner any lets builder fix a test`、`approved unlock gate opens the manifest`、`T-010 v2: the approved manifest stays open`）：只在 worktree 卡上把 T-011 的 allowed_paths 扩成 `[src/b/**, tests/b/**, package.json]`，主仓库卡仍是 `src/b/**`；规则 5 改以主仓库卡为准（A5）后这些编辑被拒。建议：夹具把扩大写进主仓库（R2）的 T-011 卡。
  2. 同文件 night 一节（6 条：`night: red merge undone…`、`reopened task integrates on retry`、`first attempt's good change survives`、`all three integrated`、`morning: lists the reopened task`、`morning: three diffs`）：claude-night 的 T-021 写 `src/bad.txt`，不在它的 `src/b/**` 内，现在在 finish 就被范围拦下（`✗ T-021 超出任务范围：src/bad.txt`），走不到「整合红 → 撤回重开」。建议：bad 文件改放 `src/b/` 下（verify.sh 同步改），或 T-021 卡 allowed_paths 加 `src/bad.txt`。
  3. 同文件「control paths (T-009)」RC4（15 条，`ctl: no green integration for T-040` 起到 `v3 push: integration pushed…`）：claude-ctl 的 T-041 写 `package.json`（v2 #10 网络白名单用例），不在 `src/T041/**` 内 → 被拦，后面依赖 T-041 整合的断言全挂。建议：`mkcard T-041 S "src/T041/**, package.json"`。
  4. `pkg/tests/test_lifecycle.sh` 第 240、452 行（`own task card writable despite locked_paths .harness/**`、`v2-2: own card still writable under the main card's .harness/**`）：用 Write 把本任务卡整个写成 `x\n`，等于删掉 allowed_paths/locked_paths/unlock 等字段，规则 5a 拒绝。建议：夹具改成写回原 frontmatter + 新正文（意图是验证 locked_paths 不锁自己的卡，与范围字段无关）。
  5. `pkg/tests/test_lifecycle.sh`「unlock: another task id gets nothing」：`cdiff(sha4, "T-202")` 期望不含 `LICENSE` / `src/core/a.py`；T-202 卡 allowed_paths 是 `src/T-202/**`，这两个文件现在是 T-202 的范围外命中。建议：断言只看 control 类（`control_diff_categories(...)["control"]`）。
  草稿实现下除以上 28 条外，test-harness 与 pkg/tests 其余用例（含全部新用例）都通过；插件相关失败只因草稿目录没有 plugins/（未验证改夹具后的结果）。

- 2026-11-15 编排方决定：按建议 1–5 调整夹具，保持原测试意图；第 5 条另加 scope 断言
- tester 2026-11-15：已按 1–5 改夹具（未删断言）：test-harness.sh 在 R2 主仓库卡上扩大 T-011（本节末还原）、night 的 bad 文件移到 `src/b/bad.txt`（verify.sh 与断言路径同步）、`mkcard T-041 S "src/T041/**, package.json"`；test_lifecycle.sh 用 `keep_fm()` 写回原 frontmatter + 新正文，T-202 断言改看 `["control"]` 并加 `["scope"] == ['LICENSE', 'src/core/a.py']`。草稿实现下 test-harness 379/379、pkg/tests 除插件打包用例（草稿目录无 plugins/）外全过。

- tester 2026-11-15（v2，安全挑错第 1 轮）需求变更：① ctl 门卡不再经 unlock 路径放行（F1）；② 控制面自动提交不提交已有任务卡的范围字段、有未答复 ctl 门卡的任务不重派（F2）；③ 自己的卡只认基准里那个文件名（F3）；④ gate_github 推送附件用调度器记录的任务基线（D1）。**范围扩大请求**：F2 要改 `pkg/scripts/new-task.sh`（认领提交也经 `stage-bookkeeping`）及插件副本 `plugins/harness/payload/scripts/new-task.sh`——它们不在本卡 allowed_paths 内，需人在 main 上把这两个路径加进本卡并提交；不加的话 test-harness「scope v2」里 T-142（认领前主仓库卡已被改宽）一条会一直红。

- tester 2026-11-16（v2）**与 F2 冲突的已有用例（未改动，待编排方决定）**：`pkg/scripts/test-harness.sh`「lifecycle (T-021 v2)」4 条（`repeat ctl block -> new gate G-T241-ctl-2`、`G-T241-ctl-2 card has id`、`second run really ran T-241`、`task blocked again`）：人在 G-T241-ctl 仍未答复时 `set-status T-241 ready` 并期望重派；F2「有未答复 ctl 门卡不重派」后不再派发。建议夹具：设回 ready 前先在终端答复 `G-T241-ctl B`（卡上选项 B = 退回重做，正是这个流程），断言不变。
- tester 2026-11-16（v2）给 builder 的提醒：草稿实现里每次派发多了 stage-bookkeeping + 记录基线，`parallel: they overlapped in time`（假会话只睡 2 秒）稳定失败；不是约定冲突，实现要让认领到启动之间的额外开销远小于 2 秒（例如只在有 `.harness/tasks/` 改动时才逐卡比较）。
- tester 2026-11-16（v2）结果：test_scope.sh 158 条（v2 37 条，当前 23 条失败，v1 121 条全过）；test-harness.sh 394 条（当前 384，10 条 scope v2 失败，已有全过）；pkg/tests 其余全过。草稿实现（/tmp，未提交）下 v2 新用例全过，失败只有上面 4 条 T-021 v2 + overlap 计时 + 插件打包（草稿目录无 plugins/）。

- 2026-11-16 编排方决定：`pkg/scripts/new-task.sh` 已加进 T-024 的 allowed_paths（main 9bf2d2e，worktree 卡同步）；`plugins/harness/**` 原本就在范围内。
- 2026-11-16 编排方决定：采纳 T-241 夹具建议——`set-status T-241 ready` 之前先在终端答复 `G-T241-ctl B`，四条断言不变（tester 已改 test-harness.sh）。

- tester 2026-11-16（v3，安全挑错第 2 轮）需求变更：① 记录提交改用临时索引，只提交 `.harness`（+ lessons.md），用户自己暂存的文件保持暂存（N1）；② 取消 new-task 的「只改 status」快路径，frontmatter 坏掉 / 范围字段消失也挡回（N2）；③ 同一任务号新增第二张卡不提交，基准里有多张卡时范围检查失败即拦（N3）。新增 CLI `commit-bookkeeping`；`stage-bookkeeping` 保留。

- tester 2026-11-16（v3）结果：test_scope.sh 188 条（v3 30 条，当前 16 条失败；v1/v2 全过）；test-harness.sh 408 条（当前 398，10 条 scope v3 失败，已有全过）；pkg/tests 其余全过。草稿实现（/tmp，已删）下 test-harness 408/408；test_scope 只剩两条草稿没做的约定（N3 locked_paths 对多张卡取并集、doctor 多卡一行）。

- 2026-11-16 编排方决定：`parallel: they overlapped in time` 改成与计时无关（假会话等同批另一个会话的 start 行出现再结束，最多 30 秒），断言不变；减少每次派发的开销 → §8（S-004）。tester 结果：test-harness 连跑 3 次 407/408、408/408、408/408，唯一一次失败是无关的 `v3 receivepack: tamper actually happened (fixture sanity)`（见 §8）。

## 10. Verifier 结论
- 结论：PASS
- 说明：独立复验第 1 轮 PASS（288fed7，A1–A8 用自建仓库逐条复现；night-mode --scope-base 偏离判定正确）；安全挑错 3 轮后 PASS（151f2f1）：F1 ctl 批准只按内容放行、F2 replan 改范围字段不会被自动提交且有未答 ctl 门卡不重派、F3 冒充自己的卡、D1 夜间附件推送基线、N1 自动提交只用临时索引不扫走用户暂存、N2 去掉 status 快速路径且破坏 frontmatter 的卡被扣留、N3 新增 / 改名冒充卡被扣留且基准里多张卡一律拦下。并行重叠测试改为按顺序判定（3927055），receivepack 夹具加标记与日志（278baf4）。test_scope 188/188、test-harness 410/410、test_lifecycle 192/192、其余全 N/N，verify.sh rc=0。

## 11. 尝试日志（每次修复前先写假设；同一问题最多 5 次）
| # | 假设 | 改动 | 结果 |
|---|---|---|---|
| 1 | 按接口约定实现：基准卡范围 + ctl 快照按 (fold 路径, mode oid) 放行；范围 diff 基线 scope_base → HARNESS_BASE → HARNESS_INTEGRATION → base | harness_lib / protect_paths / harness-loop / doctor | test_scope 首跑 100/121（只剩 protect_paths、doctor），补齐后 121/121 |
| 2 | 整合时 HARNESS_BASE=整合分支已指向合并结果，范围 diff 为空 → 改用合并前提交作范围基线 | integrate 加 `--scope-base "$pre"` | test-harness 379/379 |
| 3 | v2：自动提交按暂存区挡范围字段；提交改为提交暂存区（不带 pathspec，否则会绕过暂存区） | harness_lib / harness-loop / new-task / gate_github | 全过；但 parallel 重叠用例余量从约 0.8s 降到约 0.4s |
| 4 | 派发路径多出的开销来自 new-task 每次起 python 比较卡、record_base 在派发间 | 认领只改 status 行时走 git add 快路径（白名单正则，其他一律逐卡比较）；基线在本批会话启动后一次记完 | new-task 每次约 1.15s，与 288fed7 持平；test-harness 394/394 |
| 5 | v3：快路径是文本捷径、会被挪行绕过 → 取消；记录提交改用临时索引不碰用户索引；同号多卡失败即拦 | harness_lib / new-task / harness-loop / doctor | test_scope 188/188、test-harness 408/408 |

## 12. 教训（同一个错误第二次出现时写一行可执行的规则，调度器会同步到 .claude/rules/lessons.md）

## 13. 对抗审查
| 轮 | 挑错数 | 成立 | 已处理 | 说明 |
|---|---|---|---|---|
| 1 | 4 | 4 | 4 | F1 ctl 批准按路径放行（必修）、F2 replan 自动提交扩大范围、F3 冒充卡、D1（复验）夜间附件推送误拦 |
| 2 | 3 | 3 | 3 | N1 自动提交扫走用户暂存、N2 status 快速路径破坏 frontmatter、N3 新增冒充卡被提交 |
| 3 | 1 | 1 | 1 | PASS；计时测试余量 0.6 s，改为按顺序判定；receivepack 一次性失败查无根因，夹具加诊断 |
