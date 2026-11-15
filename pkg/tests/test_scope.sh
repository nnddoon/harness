#!/usr/bin/env bash
# T-024 验收：控制面按基准任务卡（main 上已提交的卡）检查改动范围（control-diff --task）、已批准的 ctl 门卡按内容放行、
# protect_paths 规则 5 以主仓库卡为准并拒绝改本任务卡的范围字段、doctor 提醒没写 allowed_paths 的任务、gate_github 推送检查。
# 调度器接入（harness-loop finish / integrate / ctl_block）的用例在 pkg/scripts/test-harness.sh「scope (T-024)」一节。
# 按任务卡「接口约定」。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$SRC/.claude/hooks/harness_lib.py"
HOOKS="$SRC/.claude/hooks"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-scope.XXXXXX")"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
has() { grep -qF -- "$2" "$1" 2>/dev/null && echo yes || echo no; }
PY3="$(command -v python3)"
OUT="$T/out"
HOMED="$T/home"; XDG="$T/state"; mkdir -p "$HOMED" "$XDG"
unset HARNESS_GUARD HARNESS_MODE HARNESS_UNATTENDED HARNESS_INTEGRATION HARNESS_BASE HARNESS_STRICT HARNESS_GATE_PUSH_ASSETS
export XDG_STATE_HOME="$XDG"
G=(git -c user.name=t -c user.email=t@t)

# q <python> [repo] [args…] —— 进程内调用 harness_lib（H）/ gate_github（GG），异常打印成 ERR …（不中断脚本）
cat > "$T/q.py" <<'PY'
import os, sys
sys.path.insert(0, os.environ["HOOKS"])
import harness_lib as H
from pathlib import Path
R = Path(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
A = sys.argv[3:]
try:
    exec(sys.argv[1])
except SystemExit:
    raise
except BaseException as e:
    print(f"ERR {type(e).__name__}: {e}")
PY
q() { (cd "$T" && HOOKS="$HOOKS" XDG_STATE_HOME="$XDG" "$PY3" -B "$T/q.py" "$@" 2>&1 | tail -1); }

# cd_run <dir> <harness_lib args…>   结果：$OUT/{rc,stdout,stderr}；额外环境变量放进 XENV=(K=V …)
XENV=()
cd_run() {
  local d="$1"; shift
  rm -rf "$OUT"; mkdir -p "$OUT"
  ( cd "$d" && env -i HOME="$HOMED" PATH="$PATH" XDG_STATE_HOME="$XDG" ${XENV[@]+"${XENV[@]}"} "$PY3" "$LIB" "$@" ) \
    > "$OUT/stdout" 2> "$OUT/stderr"
  echo $? > "$OUT/rc"
}
rc() { cat "$OUT/rc"; }
lines() { paste -sd'|' "$OUT/stdout" 2>/dev/null; }
cdiff() { cd_run "$T" control-diff "$@" --root "$R"; }   # 用当前的 $R
res() { echo "$(rc) $(lines)"; }

# mkc <dir> <tid> <allowed_paths 原文 | -> —— 任务卡（- = 不写 allowed_paths 这一行）
mkc() {
  local al=""; [ "$3" != "-" ] && al="allowed_paths: $3"$'\n'
  mkdir -p "$1/.harness/tasks"
  printf -- '---\nid: %s\ntitle: x\nstatus: in_progress\nrisk: low\nbranch: task/%s-x\n%slocked_paths: []\nunlock: []\nauto_ok: no\n---\n\n# %s x\n\n## 7. 当前进展\n- 无\n' \
    "$2" "$2" "$al" "$2" > "$1/.harness/tasks/$2-x.md"
}
# mkctl <dir> <gid> <tid> —— 调度器写在主仓库的 ctl 门卡（与 harness-loop ctl_block 同形）
mkctl() {
  mkdir -p "$1/.harness/gates"
  printf -- '---\nid: %s\ntask: %s\nkind: unlock\nstatus: open\ncreated: 2026-11-15\nrecommended: B\nanswer:\napprove_options: [A]\n---\n\n# %s %s 超出任务范围：批准这些改动吗？\n\n## 选项\n- **A**：批准这些改动 — 后果：你人工合并这个分支\n- **B（推荐）**：退回重做\n' \
    "$2" "$3" "$2" "$3" > "$1/.harness/gates/$2.md"
}
br() {  # br <name> <shell…>：从 main 开分支，执行改动，提交，回到 main
  local name="$1"; shift
  git checkout -q -b "$name" main && eval "$*" && git add -A && "${G[@]}" commit -qm "$name" && git checkout -q -f main
}
sha() { git -C "$R" rev-parse "$1"; }

# ################################################################ 仓库 R：verify.sh 不跑 npm（没有 JS 入口清单）
R="$T/repo"; mkdir -p "$R"; cd "$R" || exit 1
git init -q -b main
mkdir -p src docs scripts .harness
echo a > src/a.js; echo d > docs/x.md; echo x > scripts/x.sh; echo 'module.exports = {}' > jest.config.js
printf '{"name":"demo","scripts":{"test":"jest"}}\n' > package.json
printf '#!/usr/bin/env bash\nexit 0\n' > .harness/verify.sh
printf '.claude/worktrees/\n__pycache__/\n' > .gitignore
mkc . T-301 '[src/**]'; mkc . T-302 -; mkc . T-303 '[]'; mkc . T-304 'src/**'; mkc . T-305 '[src/**]'
mkc . T-306 '[src/**]'; mkc . T-307 '[src/**]'; mkc . T-308 '[src/**]'; mkc . T-309 '[src/**]'; mkc . T-310 '[src/**]'
mkc . T-311 '[src/**]'; mkc . T-313 '[lib/**]'; mkc . T-314 '[/abs/**, ../up/**]'; mkc . T-315 '[src/]'
mkc . T-330 -; mkc . T-331 -; mkc . T-332 -
cat > .harness/backlog.md <<'EOF'
# Backlog

- T-301 | ready | P1 | a | deps: - | auto_ok: no | owner: -
- T-302 | in_progress | P1 | b | deps: - | auto_ok: no | owner: -
- T-303 | claimed | P1 | c | deps: - | auto_ok: no | owner: -
- T-330 | done | P1 | d | deps: - | auto_ok: no | owner: -
- T-331 | proposed | P1 | e | deps: - | auto_ok: no | owner: -
- T-332 | in_progress | P1 | f | deps: - | auto_ok: no | owner: -
EOF
git add -A && "${G[@]}" commit -qm init

br s-in      'echo b >> src/a.js; mkdir -p src/n && echo n > src/n/new.js'
br s-out     'echo b >> src/a.js; cat > docs/new.md <<EOF
made by a Bash heredoc, not by Edit
EOF'
br s-own     'sed -i.bak "s/^- 无/- 做了一半/" .harness/tasks/T-301-x.md; rm -f .harness/tasks/*.bak;
              mkdir -p .harness/handoffs .harness/gates/G-T301-1; echo h > .harness/handoffs/T-301.md;
              printf -- "---\nid: G-T301-1\nkind: design\n---\n# q\n" > .harness/gates/G-T301-1.md; echo png > .harness/gates/G-T301-1/a.png'
br s-ctlcard 'mkdir -p .harness/gates/G-T301-ctl-2; printf -- "---\nkind: unlock\n---\n" > .harness/gates/G-T301-ctl.md; echo p > .harness/gates/G-T301-ctl-2/x.png'
br s-widen   'sed -i.bak "s#^allowed_paths: .*#allowed_paths: [src/**, docs/**]#" .harness/tasks/T-301-x.md; rm -f .harness/tasks/*.bak; echo w > docs/new.md'
br s-del     'git rm -q docs/x.md'
br s-ren-out 'mkdir -p lib && git mv src/a.js lib/a.js'
br s-ren-in  'git mv docs/x.md src/x.md'
br s-case    'mkdir -p SRC && echo c > SRC/c.js'
br s-other   'echo more >> .harness/tasks/T-302-x.md'
br s-mixed   'echo y >> scripts/x.sh; echo m > docs/new.md'
br s-harness 'echo n > .harness/notes.txt'
br s-plugins 'mkdir -p plugins/harness && echo "{}" > plugins/harness/x.json'
br s-jest    'echo "module.exports = { testMatch: [], passWithNoTests: true }" > jest.config.js'
cd "$T"

# ================================================================ task_scope：基准卡的 allowed_paths
expect "task_scope: list form" "['src/**']" "$(q 'print(H.task_scope(R, "main", "T-301"))' "$R")"
expect "task_scope: no allowed_paths line -> None" "None" "$(q 'print(H.task_scope(R, "main", "T-302"))' "$R")"
expect "task_scope: allowed_paths: [] -> None" "None" "$(q 'print(H.task_scope(R, "main", "T-303"))' "$R")"
expect "task_scope: scalar src/** == [src/**]" "['src/**']" "$(q 'print(H.task_scope(R, "main", "T-304"))' "$R")"
expect "task_scope: trailing slash src/ -> src/**" "['src/**']" "$(q 'print(H.task_scope(R, "main", "T-315"))' "$R")"
expect "task_scope: only absolute / .. entries -> [] (still checked)" "[]" "$(q 'print(H.task_scope(R, "main", "T-314"))' "$R")"
expect "task_scope: no card -> None" "None" "$(q 'print(H.task_scope(R, "main", "T-999"))' "$R")"
expect "task_scope: bad task id -> None" "None" "$(q 'print(H.task_scope(R, "main", "x"))' "$R")"
expect "task_scope: branch card is not the base card (s-widen ref has docs/**)" "['src/**', 'docs/**']" \
  "$(q 'print(H.task_scope(R, "s-widen", "T-301"))' "$R")"

# ================================================================ A1：范围外的文件命中（Edit 或 Bash 写的都一样：看的是提交）
cdiff main s-in --task T-301
expect "A1 in-scope branch: exit 0, nothing" "0 " "$(res)"
cdiff main s-out --task T-301
expect "A1 Bash-created docs/new.md outside src/**: exit 1, listed alone" "1 docs/new.md" "$(res)"
cdiff main s-out
expect "A1 without --task: no scope check (output unchanged)" "0 " "$(res)"
cdiff main s-out --task T-302
expect "A1/A6 base card without allowed_paths: no scope check" "0 " "$(res)"
cdiff main s-out --task T-303
expect "A1/A6 base card allowed_paths: [] -> no scope check" "0 " "$(res)"
cdiff main s-out --task T-304
expect "A1 scalar allowed_paths works" "1 docs/new.md" "$(res)"
cdiff main s-in --task T-315
expect "A1 allowed src/ covers src/n/new.js" "0 " "$(res)"
cdiff main s-in --task T-314
expect "A1 all-invalid allowed_paths: everything outside own paths hits" "1 src/a.js|src/n/new.js" "$(res)"
cdiff main s-out --task T-999
expect "A1 task without a card: no scope check" "0 " "$(res)"
cdiff main s-own --task T-301
expect "A1 own card / handoff / gate card + assets are not scope hits" "0 " "$(res)"
cdiff main s-ctlcard --task T-301
expect "A1 ctl gate card and its assets on the branch are scope hits" "1 .harness/gates/G-T301-ctl-2/x.png|.harness/gates/G-T301-ctl.md" "$(res)"
cdiff main s-del --task T-301
expect "A1 delete outside scope counts" "1 docs/x.md" "$(res)"
cdiff main s-ren-out --task T-301
expect "A1 rename src/a.js -> lib/a.js: new name hits (old name in scope)" "1 lib/a.js" "$(res)"
cdiff main s-ren-in --task T-301
expect "A1 rename docs/x.md -> src/x.md: old name hits" "1 docs/x.md" "$(res)"
cdiff main s-case --task T-301
expect "A1 case folded like the rest of control_diff: SRC/c.js matches src/**" "0 " "$(res)"
cdiff main s-other --task T-301
expect "A1 another task's card is not own bookkeeping" "1 .harness/tasks/T-302-x.md" "$(res)"
cdiff main s-harness --task T-301
expect "A1 other .harness/ files are not exempt" "1 .harness/notes.txt" "$(res)"
cdiff main s-plugins --task T-301
expect "A1 plugins/harness/** is an ordinary path" "1 plugins/harness/x.json" "$(res)"
cdiff main s-mixed --task T-301
expect "A1 control + scope hits: flat output, sorted" "1 docs/new.md|scripts/x.sh" "$(res)"
cdiff main s-mixed --task T-301 --categories
expect "A1 --categories: control lines first, then scope (tab-separated)" "1 control	scripts/x.sh|scope	docs/new.md" "$(res)"
cdiff main s-mixed --categories
expect "A1 --categories without --task: control only" "1 control	scripts/x.sh" "$(res)"
cdiff main s-in --task T-301 --categories
expect "A1 --categories, no hit: exit 0, nothing" "0 " "$(res)"
expect "A1 control_diff(task=) in-process" "['docs/new.md']" "$(q 'print(H.control_diff(R, "main", "s-out", task="T-301"))' "$R")"
expect "A1 control_diff_categories in-process" "{'control': ['scripts/x.sh'], 'scope': ['docs/new.md']}" \
  "$(q 'print(H.control_diff_categories(R, "main", "s-mixed", task="T-301"))' "$R")"
expect "A1 control_diff without task unchanged in-process" "['scripts/x.sh']" "$(q 'print(H.control_diff(R, "main", "s-mixed"))' "$R")"
cdiff main s-in --task T-301 --card-ref
expect "A1 --card-ref without value -> exit 2" 2 "$(rc)"
cdiff main s-in --task T-301 --scope-base
expect "A1 --scope-base without value -> exit 2" 2 "$(rc)"
cdiff main s-in --task T-301 --card-ref -x
expect "A1 --card-ref starting with - -> exit 2" 2 "$(rc)"

# ================================================================ A4：R-1 复现，没有 JS 清单也被范围拦下
cdiff main s-jest
expect "A4 R-1 (verify.sh without npm): no task -> not a control file" "0 " "$(res)"
cdiff main s-jest --task T-301
expect "A4 R-1: card allowed_paths src/** -> jest.config.js caught by scope" "1 jest.config.js" "$(res)"
cdiff main s-jest --task T-301 --categories
expect "A4 R-1: labelled scope" "1 scope	jest.config.js" "$(res)"
# s003-review-r1 的原样复现（verify.sh 跑 npm run test）：T-023 照旧算控制文件；带任务号时归 control，不重复
R1="$T/r1"; mkdir -p "$R1/.harness"; cd "$R1" || exit 1
git init -q -b main
printf '#!/usr/bin/env bash\nset -e\nnpm run test\n' > .harness/verify.sh
printf '{"scripts": {"test": "jest"}}' > package.json; echo 'module.exports = {}' > jest.config.js
mkdir -p src && echo s > src/s.js; mkc . T-401 '[src/**]'
printf '# Backlog\n\n- T-401 | ready | P1 | a | deps: - | auto_ok: no | owner: -\n' > .harness/backlog.md
git add -A && "${G[@]}" commit -qm init
br t-jest 'echo "module.exports = { testMatch: [], passWithNoTests: true }" > jest.config.js'
cd "$T"
SAVE_R="$R"; R="$R1"
cdiff main t-jest
expect "A4 R-1 with npm verify: T-023 entry hit unchanged" "1 jest.config.js" "$(res)"
cdiff main t-jest --task T-401 --categories
expect "A4 R-1 with npm verify + task: control, listed once" "1 control	jest.config.js" "$(res)"
R="$SAVE_R"

# ================================================================ A2：分支扩大自己的卡不算；人在 main 上扩大并提交才算
cdiff main s-widen --task T-301
expect "A2 branch widening its own card is ignored" "1 docs/new.md" "$(res)"
cdiff main s-out --task T-301 --card-ref s-widen
expect "A2 --card-ref picks the card from that ref" "0 " "$(res)"
cd "$R" || exit 1
br s5 'echo b >> src/a.js; echo five > docs/five.md'
sed -i.bak 's#^allowed_paths: .*#allowed_paths: [src/**, docs/**]#' .harness/tasks/T-305-x.md; rm -f .harness/tasks/*.bak
cd "$T"
cdiff main s5 --task T-305
expect "A2 uncommitted widening in the main working tree does not count" "1 docs/five.md" "$(res)"
"${G[@]}" -C "$R" commit -qam "human widens T-305 on main"
cdiff main s5 --task T-305
expect "A2 widening committed on main is respected" "0 " "$(res)"

# ================================================================ 夜间模式：范围 diff 以整合分支为基（--scope-base / HARNESS_INTEGRATION）
cd "$R" || exit 1
git checkout -q -b integration/20261115 main && mkdir -p src2 && echo o > src2/other.txt && git add -A && "${G[@]}" commit -qm "T-312 integrated"
git checkout -q -b s13 && mkdir -p lib && echo l > lib/l.txt && git add -A && "${G[@]}" commit -qm s13
git checkout -q -b s13b && echo y > docs/y.md && git add -A && "${G[@]}" commit -qm s13b
git checkout -q -f main
cd "$T"
cdiff main s13 --task T-313
expect "night: against main, the integration branch's other task file counts" "1 src2/other.txt" "$(res)"
cdiff main s13 --task T-313 --scope-base integration/20261115
expect "night: --scope-base integration branch -> only the task's own changes" "0 " "$(res)"
cdiff main s13b --task T-313 --scope-base integration/20261115
expect "night: --scope-base still catches the task's own out-of-scope file" "1 docs/y.md" "$(res)"
XENV=(HARNESS_INTEGRATION=integration/20261115); cdiff main s13 --task T-313
expect "night: HARNESS_INTEGRATION=integration/… is the default scope base" "0 " "$(res)"
XENV=(HARNESS_INTEGRATION=s-in); cdiff main s13 --task T-313
expect "night: HARNESS_INTEGRATION not integration/… is ignored" "1 src2/other.txt" "$(res)"
XENV=(HARNESS_INTEGRATION=integration/nope); cdiff main s13 --task T-313
expect "night: HARNESS_INTEGRATION naming no branch is ignored" "1 src2/other.txt" "$(res)"
XENV=(HARNESS_INTEGRATION=integration/20261115); cdiff main s13
expect "night: no --task -> no scope check even with HARNESS_INTEGRATION" "0 " "$(res)"
XENV=(HARNESS_BASE=integration/20261115); cdiff main s13 --task T-313
expect "new-task base: HARNESS_BASE resolving to a commit is the default scope base" "0 " "$(res)"
XENV=(HARNESS_BASE="$(git -C "$R" rev-parse integration/20261115)"); cdiff main s13b --task T-313
expect "new-task base: HARNESS_BASE as a SHA, own out-of-scope file still caught" "1 docs/y.md" "$(res)"
XENV=(HARNESS_BASE=no-such-ref); cdiff main s13 --task T-313
expect "new-task base: HARNESS_BASE naming nothing is ignored" "1 src2/other.txt" "$(res)"
XENV=(HARNESS_BASE=main HARNESS_INTEGRATION=integration/20261115); cdiff main s13 --task T-313
expect "scope base: HARNESS_BASE wins over HARNESS_INTEGRATION" "1 src2/other.txt" "$(res)"
XENV=()

# ================================================================ A3：已批准的 ctl 门卡按快照内容放行
cd "$R" || exit 1
git checkout -q -b task/T-306-x main && echo b >> src/a.js && echo six > docs/d6.md && git add -A && "${G[@]}" commit -qm w6
S6="$(git rev-parse HEAD)"
echo changed > docs/d6.md && "${G[@]}" commit -qam w6b; S6B="$(git rev-parse HEAD)"
echo six > docs/d6.md && "${G[@]}" commit -qam w6c; S6C="$(git rev-parse HEAD)"
chmod +x docs/d6.md && "${G[@]}" commit -qam w6d; S6D="$(git rev-parse HEAD)"
git checkout -q -f main
git checkout -q -b task/T-307-x main && echo seven > docs/d7.md && git add -A && "${G[@]}" commit -qm w7; S7="$(git rev-parse HEAD)"
git checkout -q -f main
git checkout -q -b task/T-308-x main && echo eight > docs/d8.md && git add -A && "${G[@]}" commit -qm w8; S8="$(git rev-parse HEAD)"
git checkout -q -f main
git checkout -q -b task/T-310-x main && echo y >> scripts/x.sh && echo z > docs/z.md && git add -A && "${G[@]}" commit -qm w10; S10="$(git rev-parse HEAD)"
git checkout -q -f main
git checkout -q -b task/T-311-x main && echo u > docs/u.md && echo v > docs/v.md && git add -A && "${G[@]}" commit -qm w11; S11="$(git rev-parse HEAD)"
git checkout -q -f main
MAIN="$(git rev-parse main)"
mkctl "$R" G-T306-ctl T-306; mkctl "$R" G-T307-ctl T-307; mkctl "$R" G-T308-ctl T-308; mkctl "$R" G-T310-ctl T-310
cd "$T"

expect "A3 record_ctl_scope writes the record" True "$(q 'print(H.record_ctl_scope(R, "G-T306-ctl", "T-306", A[0], ["docs/d6.md"]))' "$R" "$S6")"
expect "A3 record_ctl_scope never overwrites (O_EXCL)" False "$(q 'print(H.record_ctl_scope(R, "G-T306-ctl", "T-306", A[0], ["src/a.js"]))' "$R" "$S6")"
expect "A3 record: gid / task / commit / files with '<mode> <oid>'" "G-T306-ctl T-306 yes ['docs/d6.md'] yes" "$(q '
s = H.read_ctl_scope(R, "G-T306-ctl") or {}
oid = __import__("subprocess").run(["git", "rev-parse", A[0] + ":docs/d6.md"], cwd=R, capture_output=True, text=True).stdout.strip()
print(s.get("gid"), s.get("task"), "yes" if s.get("commit") == A[0] else "no", sorted(s.get("files") or {}),
      "yes" if (s.get("files") or {}).get("docs/d6.md") == "100644 " + oid else "no")' "$R" "$S6")"
expect "A3 record_ctl_scope: not a ctl gid -> False" False "$(q 'print(H.record_ctl_scope(R, "G-T309-1", "T-309", A[0], ["docs/x.md"]))' "$R" "$MAIN")"
expect "A3 record_ctl_scope: task does not match the gid -> False" False "$(q 'print(H.record_ctl_scope(R, "G-T309-ctl-3", "T-301", A[0], ["docs/x.md"]))' "$R" "$MAIN")"
expect "A3 record_ctl_scope: short / non-hex commit -> False" False "$(q 'print(H.record_ctl_scope(R, "G-T309-ctl-4", "T-309", "deadbeef", ["docs/x.md"]))' "$R")"
expect "A3 record_ctl_scope: unknown commit -> False" False "$(q 'print(H.record_ctl_scope(R, "G-T309-ctl-5", "T-309", "0" * 40, ["docs/x.md"]))' "$R")"
expect "A3 record_ctl_scope: a deleted file is recorded as ''" "''" "$(q '
H.record_ctl_scope(R, "G-T309-ctl-6", "T-309", A[0], ["docs/gone.md"]); print(repr((H.read_ctl_scope(R, "G-T309-ctl-6") or {}).get("files", {}).get("docs/gone.md")))' "$R" "$MAIN")"
expect "A3 next_ctl_gid skips a number that already has a scope record" "G-T309-ctl-2" \
  "$(q 'H.record_ctl_scope(R, "G-T309-ctl", "T-309", A[0], ["docs/x.md"]); print(H.next_ctl_gid(R, "T-309"))' "$R" "$MAIN")"

cdiff main "$S6" --task T-306
expect "A3 open ctl gate (recorded, not answered): still hits" "1 docs/d6.md" "$(res)"
expect "A3 answer G-T306-ctl A" True "$(q 'print(H.answer_gate(R, "G-T306-ctl", "A", "", "终端")[0])' "$R")"
cdiff main "$S6" --task T-306
expect "A3 approved: the snapshotted file at that content passes" "0 " "$(res)"
expect "A3 approved_scope has (folded path, entry)" yes \
  "$(q 'print("yes" if any(p == "docs/d6.md" and e.startswith("100644 ") for p, e in H.approved_scope(R, "T-306")) else "no")' "$R")"
cdiff main "$S6B" --task T-306
expect "A3 file changed after approval: hits again" "1 docs/d6.md" "$(res)"
cdiff main "$S6C" --task T-306
expect "A3 same content again (same blob): passes" "0 " "$(res)"
cdiff main "$S6D" --task T-306
expect "A3 mode change (chmod +x) counts as a change" "1 docs/d6.md" "$(res)"
cdiff main "$S6" --task T-301
expect "A3 approval belongs to T-306 only" "1 docs/d6.md" "$(res)"
expect "A3 ctl approval does not release the task (T-021: settle never releases on ctl)" "None" \
  "$(q 'print(H.settle_answer(R, "G-T306-ctl")[1])' "$R")"

expect "A3 record + answer B" "True rejected" \
  "$(q 'ok = H.record_ctl_scope(R, "G-T307-ctl", "T-307", A[0], ["docs/d7.md"]); print(ok, H.answer_gate(R, "G-T307-ctl", "B", "", "终端")[1])' "$R" "$S7")"
cdiff main "$S7" --task T-307
expect "A3 rejected ctl gate: still hits" "1 docs/d7.md" "$(res)"

expect "A3 answer A first, record afterwards" "True True" \
  "$(q 'a = H.answer_gate(R, "G-T308-ctl", "A", "", "终端")[0]; print(a, H.record_ctl_scope(R, "G-T308-ctl", "T-308", A[0], ["docs/d8.md"]))' "$R" "$S8")"
cdiff main "$S8" --task T-308
expect "A3 scope record newer than the answer is not honoured" "1 docs/d8.md" "$(res)"

expect "A3 record control + scope files, approve" True \
  "$(q 'H.record_ctl_scope(R, "G-T310-ctl", "T-310", A[0], ["docs/z.md", "scripts/x.sh"]); print(H.answer_gate(R, "G-T310-ctl", "A", "", "终端")[0])' "$R" "$S10")"
cdiff main "$S10" --task T-310 --categories
expect "A3 ctl approval frees scope hits only, never control files" "1 control	scripts/x.sh" "$(res)"

cdiff main "$S11" --task T-311
expect "A3/unlock before approval: both docs files hit" "1 docs/u.md|docs/v.md" "$(res)"
mkdir -p "$R/.harness/gates"
printf -- '---\nid: G-T311-1\nkind: unlock\nstatus: open\nrecommended: A\npaths: [docs/u.md]\nanswer:\n---\n\n# G-T311-1 解锁 docs/u.md？\n\n- **A（推荐）**：解锁\n- **B**：不解锁\n' > "$R/.harness/gates/G-T311-1.md"
expect "A3/unlock answer G-T311-1 A" True "$(q 'print(H.answer_gate(R, "G-T311-1", "A", "", "终端")[0])' "$R")"
cdiff main "$S11" --task T-311
expect "A3/unlock approved unlock paths are in scope for the task" "1 docs/v.md" "$(res)"

# ================================================================ gate_github：推送附件之前的 control_diff 带上范围
GR="$T/gg"; mkdir -p "$GR"; cd "$GR" || exit 1
git init -q -b main; mkdir -p src .harness; echo a > src/a.js; printf '#!/usr/bin/env bash\nexit 0\n' > .harness/verify.sh
printf '.claude/worktrees/\n__pycache__/\n' > .gitignore
mkc . T-340 '[src/**]'; mkc . T-341 '[src/**]'; git add -A && "${G[@]}" commit -qm init
git init -q --bare "$T/gg-origin.git"; git remote add origin "$T/gg-origin.git"; git push -q origin main 2>/dev/null
git checkout -q -b task/T-340-x main && echo b >> src/a.js && mkdir -p docs .harness/gates/G-T340-1 && echo o > docs/out.md \
  && echo png > .harness/gates/G-T340-1/a.png && git add -A && "${G[@]}" commit -qm w40; S40="$(git rev-parse HEAD)"
git checkout -q -f main
git checkout -q -b task/T-341-x main && echo b >> src/a.js && mkdir -p .harness/gates/G-T341-1 \
  && echo png > .harness/gates/G-T341-1/a.png && git add -A && "${G[@]}" commit -qm w41
git checkout -q -f main
cd "$T"
remote() { git --git-dir="$T/gg-origin.git" rev-parse --verify --quiet "refs/heads/$1" >/dev/null 2>&1 && echo pushed || echo not-pushed; }
q 'import gate_github as GG; GG.push_assets_ctl(R, "G-T340-1", "task/T-340-x")' "$GR" >/dev/null
expect "gate_github push_assets_ctl: out-of-scope branch not pushed" not-pushed "$(remote task/T-340-x)"
q 'import gate_github as GG; GG.push_assets_ctl(R, "G-T341-1", "task/T-341-x")' "$GR" >/dev/null
expect "gate_github push_assets_ctl: in-scope sibling pushed (control)" pushed "$(remote task/T-341-x)"
mkctl "$GR" G-T340-ctl T-340
expect "gate_github: record + approve G-T340-ctl" True \
  "$(q 'H.record_ctl_scope(R, "G-T340-ctl", "T-340", A[0], ["docs/out.md"]); print(H.answer_gate(R, "G-T340-ctl", "A", "", "终端")[0])' "$GR" "$S40")"
q 'import gate_github as GG; GG.push_assets_ctl(R, "G-T340-1", "task/T-340-x")' "$GR" >/dev/null
expect "gate_github push_assets_ctl: pushed once the ctl gate approved that content" pushed "$(remote task/T-340-x)"

# ================================================================ A5：protect_paths 以主仓库卡为准；worktree 里改范围字段被拒
P="$T/pp"; mkdir -p "$P"; cd "$P" || exit 1
git init -q -b main; mkdir -p src docs .harness; echo a > src/a.js; echo d > docs/a.md
printf '.claude/worktrees/\n__pycache__/\n' > .gitignore
mkc . T-320 '[src/**]'; mkc . T-322 '[src/**]'; mkc . T-323 -
git add -A && "${G[@]}" commit -qm init
W20="$P/.claude/worktrees/T-320"; git worktree add -q "$W20" -b task/T-320-x
( cd "$W20" && sed -i.bak 's#^allowed_paths: .*#allowed_paths: [src/**, docs/**]#' .harness/tasks/T-320-x.md && rm -f .harness/tasks/*.bak \
  && "${G[@]}" commit -qam "widen own card on the branch" )
W21="$P/.claude/worktrees/T-321"; git worktree add -q "$W21" -b task/T-321-x
( cd "$W21" && mkc . T-321 '[src/**]' && git add -A && "${G[@]}" commit -qm "card only on the branch" )
W23="$P/.claude/worktrees/T-323"; git worktree add -q "$W23" -b task/T-323-x
( cd "$W23" && sed -i.bak 's#^locked_paths: \[\]#allowed_paths: [src/**]\nlocked_paths: []#' .harness/tasks/T-323-x.md && rm -f .harness/tasks/*.bak \
  && "${G[@]}" commit -qam "narrow on the branch" )
cd "$T"
# pp <tool> <cwd> <file> [extra-json] -> allow|deny；拒绝理由写进 $T/pp.reason
pp() {
  local o
  o=$(python3 -c 'import json,sys; d={"tool_name":sys.argv[1],"cwd":sys.argv[2],"tool_input":{"file_path":sys.argv[3]}}; d["tool_input"].update(json.loads(sys.argv[4])); print(json.dumps(d))' \
      "$1" "$2" "$3" "${4:-{\}}" | (cd "$2" && env -u HARNESS_GUARD XDG_STATE_HOME="$XDG" python3 "$HOOKS/protect_paths.py"))
  printf '%s' "$o" > "$T/pp.reason"
  if printf '%s' "$o" | grep -q '"deny"'; then echo deny; else echo allow; fi
}
jedit() { python3 -c 'import json,sys; print(json.dumps({"old_string":sys.argv[1],"new_string":sys.argv[2]}))' "$1" "$2"; }
jwrite() { python3 -c 'import json,sys; print(json.dumps({"content":open(sys.argv[1],encoding="utf-8").read().replace(sys.argv[2],sys.argv[3])}))' "$1" "$2" "$3"; }
C20="$W20/.harness/tasks/T-320-x.md"

expect "A5 rule 5: main card [src/**] wins over the widened worktree card (docs denied)" deny "$(pp Edit "$W20" "$W20/docs/a.md")"
expect "A5 rule 5: message names allowed_paths" yes "$(has "$T/pp.reason" allowed_paths)"
expect "A5 rule 5: in-scope src/a.js allowed" allow "$(pp Edit "$W20" "$W20/src/a.js")"
expect "A5 rule 5: Write outside main card's scope denied" deny "$(pp Write "$W20" "$W20/docs/new.md" '{"content":"x"}')"
expect "A5 rule 5: no main card -> worktree card used (docs denied)" deny "$(pp Edit "$W21" "$W21/docs/a.md")"
expect "A5 rule 5: no main card -> worktree card used (src allowed)" allow "$(pp Edit "$W21" "$W21/src/a.js")"
expect "A5 rule 5: main card without allowed_paths -> no rule 5 restriction (worktree card ignored)" allow "$(pp Edit "$W23" "$W23/docs/a.md")"

expect "A5 own card: widening allowed_paths denied" deny "$(pp Edit "$W20" "$C20" "$(jedit 'allowed_paths: [src/**, docs/**]' 'allowed_paths: [src/**, docs/**, lib/**]')")"
expect "A5 own card: message names the field" yes "$(has "$T/pp.reason" allowed_paths)"
expect "A5 own card: message says to propose in 9. 范围变更" yes "$(has "$T/pp.reason" '9. 范围变更')"
expect "A5 own card: message says to open a gate" yes "$(has "$T/pp.reason" 'human-gate')"
expect "A5 own card: narrowing allowed_paths also denied (any change)" deny "$(pp Edit "$W20" "$C20" "$(jedit 'allowed_paths: [src/**, docs/**]' 'allowed_paths: [src/**]')")"
expect "A5 own card: locked_paths change denied" deny "$(pp Edit "$W20" "$C20" "$(jedit 'locked_paths: []' 'locked_paths: [x/**]')")"
expect "A5 own card: unlock change denied" deny "$(pp Edit "$W20" "$C20" "$(jedit 'unlock: []' 'unlock: [scripts/**]')")"
expect "A5 own card: auto_ok change denied" deny "$(pp Edit "$W20" "$C20" "$(jedit 'auto_ok: no' 'auto_ok: yes')")"
expect "A5 own card: risk change denied" deny "$(pp Edit "$W20" "$C20" "$(jedit 'risk: low' 'risk: high')")"
expect "A5 own card: status change allowed" allow "$(pp Edit "$W20" "$C20" "$(jedit 'status: in_progress' 'status: review')")"
expect "A5 own card: body (§7) change allowed" allow "$(pp Edit "$W20" "$C20" "$(jedit '- 无' '- 做了一半')")"
expect "A5 own card: Write with same frontmatter, new body allowed" allow "$(pp Write "$W20" "$C20" "$(jwrite "$C20" '- 无' '- 写完了')")"
expect "A5 own card: Write changing risk denied" deny "$(pp Write "$W20" "$C20" "$(jwrite "$C20" 'risk: low' 'risk: medium')")"
expect "A5 own card: Write changing allowed_paths denied" deny "$(pp Write "$W20" "$C20" "$(jwrite "$C20" 'docs/**]' 'docs/**, lib/**]')")"
expect "A5 own card: Edit whose old_string is not in the file is left to Edit" allow "$(pp Edit "$W20" "$C20" "$(jedit 'risk: nope' 'risk: high')")"
expect "A5 own card: replace_all over a scope field denied" deny \
  "$(pp Edit "$W20" "$C20" '{"old_string":"no","new_string":"yes","replace_all":true}')"
expect "A5 another task's card in the worktree: bookkeeping rule unchanged (allowed)" allow \
  "$(pp Edit "$W20" "$W20/.harness/tasks/T-322-x.md" "$(jedit 'allowed_paths: [src/**]' 'allowed_paths: [src/**, docs/**]')")"
expect "A5 control tower on main may widen the card (allowed)" allow \
  "$(pp Edit "$P" "$P/.harness/tasks/T-320-x.md" "$(jedit 'allowed_paths: [src/**]' 'allowed_paths: [src/**, docs/**]')")"

# ================================================================ A6：doctor 提醒进行中但没写 allowed_paths 的任务
printf '#!/bin/sh\necho "no crontab for user" >&2\nexit 1\n' > "$T/nocron"; chmod +x "$T/nocron"
# T-332：工作区里补了 allowed_paths 但没提交 —— 控制面只认提交，照样提醒
sed -i.bak 's#^locked_paths: \[\]#allowed_paths: [src/**]\nlocked_paths: []#' "$R/.harness/tasks/T-332-x.md"; rm -f "$R/.harness/tasks/"*.bak
doc() { (cd "$T" && env HARNESS_CRONTAB="$T/nocron" HARNESS_PLATFORM=linux HARNESS_GATE_CHANNEL=off XDG_STATE_HOME="$XDG" \
          "$PY3" "$SRC/bin/harness" doctor --repo "$1" > "$T/doctor.out" 2>&1); }
sec() { awk -v h="## $2" '$0==h{p=1;next} /^## /{p=0} p' "$1" 2>/dev/null; }
doc "$R"
SEC="$(sec "$T/doctor.out" 任务范围)"
expect "A6 doctor: has a 任务范围 section" yes "$(grep -qx '## 任务范围' "$T/doctor.out" && echo yes || echo no)"
expect "A6 doctor: in_progress task without allowed_paths reported" yes "$(printf '%s\n' "$SEC" | grep -q '^T-302：.*allowed_paths' && echo yes || echo no)"
expect "A6 doctor: claimed task with allowed_paths: [] reported" yes "$(printf '%s\n' "$SEC" | grep -q '^T-303：' && echo yes || echo no)"
expect "A6 doctor: uncommitted allowed_paths on main still reported" yes "$(printf '%s\n' "$SEC" | grep -q '^T-332：' && echo yes || echo no)"
expect "A6 doctor: line says how to fix (在 main 上 … 提交)" yes "$(printf '%s\n' "$SEC" | grep '^T-302：' | grep -q 'main.*提交' && echo yes || echo no)"
expect "A6 doctor: scoped ready task not reported" no "$(printf '%s\n' "$SEC" | grep -q 'T-301' && echo yes || echo no)"
expect "A6 doctor: done / proposed tasks not reported" no "$(printf '%s\n' "$SEC" | grep -qE 'T-33[01]' && echo yes || echo no)"
doc "$R1"
expect "A6 doctor: no section when every active task has allowed_paths" no "$(grep -qx '## 任务范围' "$T/doctor.out" && echo yes || echo no)"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
