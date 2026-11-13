#!/usr/bin/env bash
# T-011 验收：发布与推送移到控制面（S-002 #11）。按任务卡「接口约定」。
# strict（HARNESS_STRICT=1）下 Claude 及其 hooks 对 GitHub 写调用 0 次、推送 0 次；
# 调度器 finish() 从主仓库按 SHA 推任务分支 1 次、gh pr create 1 次、record_pr 记合并门卡；gate-sync 开门卡 Issue 1 次。
# 假 gh（pkg/tests/fake/gh_publish.py）记录每次调用；假远端（裸仓库 + update 钩子）记录每次 ref 更新；
# git 记录器记录每次 git 调用。「Claude 侧」= 假 claude 进程及其子进程（它导出 HARNESS_FAKE_CLAUDE=1，hook 继承）。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-publish.XXXXXX")"; T="$(cd "$T" && pwd -P)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
unset HARNESS_GH_TOKEN HARNESS_GATE_APPROVERS HARNESS_GATE_CHANNEL HARNESS_UNATTENDED HARNESS_MODE HARNESS_STRICT \
      HARNESS_GATE_PUSH_ASSETS HARNESS_FAKE_CLAUDE GH_TOKEN GITHUB_TOKEN HARNESS_INTEGRATION HARNESS_BASE
export XDG_STATE_HOME="$T/state" HARNESS_PLATFORM=linux
mkdir -p "$T/bin" "$T/gh" "$T/sbx" "$T/gitw" "$T/claude" "$T/state"
cp "$SRC/tests/fake/gh_publish.py" "$T/bin/gh"; chmod +x "$T/bin/gh"
export FAKEGH_DIR="$T/gh"
# strict 启动器要求 linux 上有 bwrap + socat + srt：放假的
for c in bwrap socat; do printf '#!/bin/sh\nexit 0\n' > "$T/sbx/$c"; chmod +x "$T/sbx/$c"; done
printf '#!/usr/bin/env bash\n[ "${1:-}" = --settings ] && shift 2\nexec "$@"\n' > "$T/sbx/srt"; chmod +x "$T/sbx/srt"
# git 记录器：参数（\037 分隔）\036 PWD \036 HARNESS_FAKE_CLAUDE \036 父进程命令行
REALGIT="$(command -v git)"
cat > "$T/gitw/git" <<SH
#!/usr/bin/env bash
pc="\$(tr '\\0' ' ' < /proc/\$PPID/cmdline 2>/dev/null || ps -o args= -p \$PPID 2>/dev/null)"
{ printf '%s\037' "\$@"; printf '\036%s\036%s\036%s\n' "\$PWD" "\${HARNESS_FAKE_CLAUDE:-}" "\$pc"; } >> "$T/git.log"
exec "$REALGIT" "\$@"
SH
chmod +x "$T/gitw/git"; : > "$T/git.log"
export PATH="$T/gitw:$T/bin:$T/sbx:$PATH"
PY="python3 -B"
calls() {  # calls <python 布尔表达式，c = 一条 gh 调用记录>  -> 条数
  $PY - "$FAKEGH_DIR/calls.jsonl" "$1" <<'PY'
import json, os, sys
f, expr = sys.argv[1], sys.argv[2]
rows = [json.loads(l) for l in open(f, encoding="utf-8")] if os.path.exists(f) else []
print(sum(1 for c in rows if eval(expr, {"c": c, "a": c["argv"]})))
PY
}
ghstate() { $PY -c 'import json,sys; s=json.load(open(sys.argv[1])); exec(sys.argv[2])' "$FAKEGH_DIR/state.json" "$1" 2>/dev/null; }
LIBPY() { $PY -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import harness_lib as H; R=Path(sys.argv[2]); exec(sys.argv[3])' "$RC/.claude/hooks" "$RC" "$1" 2>/dev/null; }

# ================================================================ 契约：goal_prompt / task-close（静态）
GOAL_STD="$(cd "$SRC" && $PY .claude/hooks/harness_lib.py goal T-050)"
GOAL_STRICT="$(cd "$SRC" && $PY .claude/hooks/harness_lib.py goal T-050 --strict 2>/dev/null)"
expect "goal --strict: says 不推送" yes "$(grep -qF '不推送' <<<"$GOAL_STRICT" && echo yes || echo no)"
expect "goal --strict: says 不开 PR" yes "$(grep -qF '不开 PR' <<<"$GOAL_STRICT" && echo yes || echo no)"
expect "goal --strict: names the merge gate draft G-T050-merge" yes "$(grep -qF 'G-T050-merge' <<<"$GOAL_STRICT" && echo yes || echo no)"
expect "goal --strict: still the /task-run + /task-close goal" yes "$(grep -qF '/task-close T-050' <<<"$GOAL_STRICT" && echo yes || echo no)"
expect "goal standard: unchanged (no 不推送 / 不开 PR)" no "$(grep -qE '不推送|不开 PR' <<<"$GOAL_STD" && echo yes || echo no)"
expect "goal standard: still /task-run + /task-close" yes "$(grep -qF '/task-close T-050' <<<"$GOAL_STD" && echo yes || echo no)"
expect "goal_prompt(strict=True) == CLI --strict" yes "$($PY -c 'import sys; sys.path.insert(0, sys.argv[1]); import harness_lib as H; print("yes" if H.goal_prompt("T-050", strict=True) == sys.argv[2] else "no")' "$SRC/.claude/hooks" "$GOAL_STRICT" 2>/dev/null || echo ERR)"
SK="$SRC/.claude/skills/task-close/SKILL.md"
S4="$(awk '/^4\. /{p=1} /^5\. /{p=0} p' "$SK")"
expect "task-close step 4: has a HARNESS_STRICT=1 branch" yes "$(grep -qF 'HARNESS_STRICT=1' <<<"$S4" && echo yes || echo no)"
expect "task-close step 4: strict branch leaves the branch unpushed" yes "$(grep -F 'HARNESS_STRICT=1' <<<"$S4" | grep -qE '不推送|不 push' && echo yes || echo no)"
expect "task-close step 4: standard flow still pushes + gh pr create" yes "$(grep -qF 'gh pr create' <<<"$S4" && echo yes || echo no)"

# ================================================================ 完整 strict 循环
RC="$T/repo"; mkdir -p "$RC" && cd "$RC" || exit 1
git init -q -b main && git config user.email t@t && git config user.name t
git config commit.gpgsign false; git config push.negotiate false
cp -R "$SRC/CLAUDE.md" "$SRC/.claude" "$SRC/.harness" "$SRC/scripts" .
[ -f "$SRC/.gitattributes" ] && cp "$SRC/.gitattributes" .
rm -rf .claude/worktrees .harness/logs; rm -f .harness/gates/G-*.md
printf '.claude/worktrees/\n.harness/logs/\n__pycache__/\n' > .gitignore
sed -i.bak '/^- T-001 /d' .harness/backlog.md; rm -f .harness/backlog.md.bak
mkcard() {  # mkcard <id> <paths>
  sed -e "s/T-000/$1/g" -e 's/^status: proposed /status: ready    /' \
      -e "s#^allowed_paths: \[\]#allowed_paths: [$2]#" -e "s#^branch: .*#branch: task/$1-x#" \
      .harness/tasks/_TEMPLATE.md > ".harness/tasks/$1-x.md"
  echo "- $1 | ready | P1 | $1 demo | deps: - | auto_ok: no | owner: -" >> .harness/backlog.md
}
mkcard T-050 "src/T050/**"
git add -A && git commit -qm init
ORIGIN="$T/origin.git"; git init -q --bare "$ORIGIN"; git remote add origin "$ORIGIN"; git push -q origin main 2>/dev/null
# 假远端：之后每次 ref 更新记一行「ref old new claude=<HARNESS_FAKE_CLAUDE>」
printf '#!/bin/sh\necho "$1 $2 $3 claude=${HARNESS_FAKE_CLAUDE:-}" >> "%s/remote.log"\n' "$T" > "$ORIGIN/hooks/update"
chmod +x "$ORIGIN/hooks/update"; : > "$T/remote.log"

# 假 claude：照提示词办事。提示词没说「不推送 / 不开 PR」就按 task-close 标准流程自己推分支、开 PR。
# T-050：开一张 ui 门卡（带素材）+ 合并门卡草稿，每次写门卡都跑 PostToolUse hook（继承 strict 环境）
# T-051（最后单独跑一轮）：改控制路径 scripts/（调度器应拦下，不推、不开 PR）
cat > "$T/bin/claude-pub" <<'EOF'
#!/usr/bin/env bash
export HARNESS_FAKE_CLAUDE=1
[ "${1:-}" = --settings ] && shift 2
GOAL="$2"; TID=$(printf '%s' "$GOAL" | grep -o 'T-[0-9]\{3\}' | head -1); G="$(echo "$TID" | tr -d -)"
printf '%s' "$GOAL" > "$FAKECL_DIR/goal.$TID"; env > "$FAKECL_DIR/env.$TID"
WT="$PWD"
hook() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"session_id":"s-1","tool_input":{"file_path":sys.argv[2]}}))' \
    "$WT" "$WT/.harness/gates/$1.md" | python3 "$WT/.claude/hooks/gate_github.py" hook >> "$FAKECL_DIR/hook.$TID" 2>&1
}
gate() {  # gate <gid> <kind>
  sed -e "s/G-T000-1/$1/g" -e "s/^task: T-000/task: $TID/" -e "s/^kind: ui /kind: $2 /" \
      .harness/gates/_TEMPLATE.md > ".harness/gates/$1.md"
  hook "$1"
}
if [ "$TID" = T-051 ]; then echo 'echo sneak' >> scripts/gates.sh
else mkdir -p "src/$G"; echo ok > "src/$G/a.txt"; fi
if [ "$TID" = T-050 ]; then
  mkdir -p ".harness/gates/G-$G-1"; printf 'PNG' > ".harness/gates/G-$G-1/shot.png"
  gate "G-$G-1" ui
fi
[ -n "${FAKECL_NO_MERGE:-}" ] || gate "G-$G-merge" "${FAKECL_MERGE_KIND:-irreversible}"
sed -i.bak 's/^status: [a-z_]*/status: review/' .harness/tasks/$TID*.md; rm -f .harness/tasks/*.bak
echo "# $TID handoff" > ".harness/handoffs/$TID.md"
git add -A >/dev/null; git commit -qm "$TID: work" >/dev/null
if ! { grep -qF '不推送' <<<"$GOAL" && grep -qF '不开 PR' <<<"$GOAL"; }; then
  BR="$(git branch --show-current)"
  git push -q -u origin "$BR" >/dev/null 2>&1
  gh pr create --base main --head "$BR" --title "$TID" --body x >/dev/null 2>&1
fi
exit 0
EOF
chmod +x "$T/bin/claude-pub"
export FAKECL_DIR="$T/claude"
: > "$FAKEGH_DIR/calls.jsonl"
HARNESS_CLAUDE="$T/bin/claude-pub" scripts/harness-loop.sh --max-tasks 1 --no-groom --no-replan > "$T/loop.out" 2>&1
W50="$RC/.claude/worktrees/T-050"
expect "loop: fake claude ran for T-050 under strict (HARNESS_STRICT=1)" yes "$(grep -qx 'HARNESS_STRICT=1' "$T/claude/env.T-050" 2>/dev/null && echo yes || echo no)"
expect "loop: T-050 prompt is the strict goal (不推送 + 不开 PR)" yes \
  "$(grep -qF '不推送' "$T/claude/goal.T-050" 2>/dev/null && grep -qF '不开 PR' "$T/claude/goal.T-050" && echo yes || echo no)"
expect "loop: T-050 in review" 1 "$(grep -c '^- T-050 | review' .harness/backlog.md)"

# ---- Claude 侧：0 次 gh 写、0 次推送；strict 下 publish hook 是空操作
expect "claude side: 0 gh write calls (process + hooks)" 0 "$(calls 'c["claude"] == "1" and c["write"]')"
expect "claude side: strict publish hook makes no gh call at all" 0 "$(calls 'c["claude"] == "1"')"
expect "claude side: 0 git push invocations" 0 "$($PY - "$T/git.log" <<'PY'
import sys
n = 0
for l in open(sys.argv[1], encoding="utf-8", errors="replace"):
    p = l.rstrip("\n").split("\x1e")
    if len(p) < 4 or p[2] != "1":
        continue
    a = p[0].split("\x1f")[:-1]
    i = 0
    while i < len(a) and a[i] in ("-c", "-C"):
        i += 2
    n += i < len(a) and a[i] == "push"
print(n)
PY
)"
expect "claude side: 0 ref updates on the remote" 0 "$(grep -c 'claude=1$' "$T/remote.log")"
expect "strict hook: gate card untouched (no issue: written)" "" "$(sed -n 's/^issue:[[:space:]]*\([^#]*\).*/\1/p' "$W50/.harness/gates/G-T050-1.md" | sed 's/[[:space:]]*$//')"
expect "strict hook: no issue mapping in the store after the loop" none "$(LIBPY 'n=H.read_issue(R, "G-T050-1"); print(n or "none")' || echo ERR)"

# ---- 调度器：推任务分支 1 次（主仓库、按 SHA、control-diff 之后）、开 PR 1 次、record_pr
SHA50="$(git rev-parse --verify --quiet 'refs/heads/task/T-050-x^{commit}')"
expect "scheduler: exactly 1 ref update on the remote" 1 "$(grep -c . "$T/remote.log")"
expect "scheduler: that update is task/T-050-x to the branch's SHA" "refs/heads/task/T-050-x $SHA50" \
  "$(awk '{print $1, $3}' "$T/remote.log" | head -n1)"
expect "scheduler: pushed from the main repo as <sha>:refs/heads/task/T-050-x" yes "$($PY - "$T/git.log" "$RC" <<'PY'
import os, re, sys
root = os.path.realpath(sys.argv[2]); pushes = []
for l in open(sys.argv[1], encoding="utf-8", errors="replace"):
    p = l.rstrip("\n").split("\x1e")
    if len(p) < 4 or p[2] or "harness-loop.sh" not in p[3]:
        continue
    a = p[0].split("\x1f")[:-1]; i, cdir = 0, None
    while i < len(a) and a[i] in ("-c", "-C"):
        if a[i] == "-C":
            cdir = a[i + 1]
        i += 2
    if i < len(a) and a[i] == "push":
        pushes.append((os.path.realpath(cdir or p[1]), a[i + 1:]))
t = [x for x in pushes if any("task/T-050-x" in y for y in x[1])]
ok = len(t) == 1 and t[0][0] == root and any(re.fullmatch(r"[0-9a-f]{40}:refs/heads/task/T-050-x", y) for y in t[0][1])
print("yes" if ok else "no")
PY
)"
expect "scheduler: exactly 1 gh pr create" 1 "$(calls 'a[:2] == ["pr", "create"]')"
expect "scheduler: pr create not from claude, --head task/T-050-x" 1 \
  "$(calls 'a[:2] == ["pr", "create"] and c["claude"] == "" and "--head" in a and a[a.index("--head") + 1] == "task/T-050-x"')"
expect "record_pr: merge gate G-T050-merge -> PR #101" 101 "$(LIBPY 'print(H.read_pr(R, "G-T050-merge"))' || echo ERR)"
expect "record_pr: exactly one PR mapping" "G-T050-merge:101" "$(LIBPY 'print(",".join(f"{g}:{n}" for g, n in H.pr_gates(R)))' || echo ERR)"

# ---- gate-sync：开门卡 Issue 1 次（控制面）；合并门卡挂到 PR；重复运行不重复发布
(cd "$RC" && scripts/gate-sync.sh > "$T/gs1.out" 2>&1)
GS1="$(calls 'c["write"] and a[:2] != ["label", "create"]')"
(cd "$RC" && scripts/gate-sync.sh > "$T/gs2.out" 2>&1)
expect "v2(5) second gate-sync: no new issue / comment / PR write" "$GS1" "$(calls 'c["write"] and a[:2] != ["label", "create"]')"
expect "v2(2) pubclaim recorded for G-T050-1 (main run)" True "$(LIBPY 'print((H.answers_dir(R) / "G-T050-1.pubclaim.json").is_file())' || echo ERR)"
expect "gate-sync: exactly 1 gh issue create overall" 1 "$(calls 'a[:2] == ["issue", "create"]')"
expect "gate-sync: the issue create is not from claude" 1 "$(calls 'a[:2] == ["issue", "create"] and c["claude"] == ""')"
expect "gate-sync: the issue is gate G-T050-1" yes "$(ghstate 'print("yes" if len(s["issues"]) == 1 and "G-T050-1" in (s["issues"][0]["title"] or "") else "no")' || echo no)"
expect "gate-sync: issue mapping recorded (G-T050-1 -> #1)" 1 "$(LIBPY 'print(H.read_issue(R, "G-T050-1"))' || echo ERR)"
expect "gate-sync: merge gate not published as an issue" none "$(LIBPY 'print(H.read_issue(R, "G-T050-merge") or "none")' || echo ERR)"
expect "gate-sync: merge gate attached to PR #101 (comment names it)" yes \
  "$(ghstate 'print("yes" if any("G-T050-merge" in c for p in s["prs"] if p["number"] == 101 for c in p["comments"]) else "no")' || echo no)"
expect "gate assets: on the remote task branch" yes \
  "$(git --git-dir="$ORIGIN" cat-file -e 'refs/heads/task/T-050-x:.harness/gates/G-T050-1/shot.png' 2>/dev/null && echo yes || echo no)"
expect "gate assets: issue body links the asset" yes "$(ghstate 'print("yes" if ".harness/gates/G-T050-1/shot.png" in s["issues"][0]["body"] else "no")' || echo no)"
expect "after gate-sync: still exactly 1 task-branch push on the remote, 0 from claude" "1 0" \
  "$(grep -c 'refs/heads/task/' "$T/remote.log") $(grep -c 'claude=1$' "$T/remote.log")"
expect "overall: 0 gh writes from claude" 0 "$(calls 'c["claude"] == "1" and c["write"]')"

# ================================================================ hook 直接调用：strict 空操作 / standard 照旧
mkhookgate() {  # mkhookgate <gid> —— 在 T-050 worktree 写一张带素材的 ui 门卡
  sed -e "s/G-T000-1/$1/g" -e 's/^task: T-000/task: T-050/' "$W50/.harness/gates/_TEMPLATE.md" > "$W50/.harness/gates/$1.md"
  mkdir -p "$W50/.harness/gates/$1"; printf 'PNG' > "$W50/.harness/gates/$1/s.png"
}
runhook() {  # runhook <gid> [env…]
  local g="$1"; shift
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"session_id":"s-2","tool_input":{"file_path":sys.argv[2]}}))' \
    "$W50" "$W50/.harness/gates/$g.md" | (cd "$W50" && env "$@" python3 .claude/hooks/gate_github.py hook)
}
export FAKEGH_DIR="$T/gh2"; mkdir -p "$FAKEGH_DIR"; : > "$FAKEGH_DIR/calls.jsonl"; : > "$T/remote.log"
mkhookgate G-T050-4
SUM4="$(cksum < "$W50/.harness/gates/G-T050-4.md")"; HEAD4="$(git -C "$W50" rev-parse HEAD)"
OUT4="$(runhook G-T050-4 HARNESS_STRICT=1 HARNESS_FAKE_CLAUDE=1)"
expect "strict hook: no gh call" 0 "$(calls 'True')"
expect "strict hook: no output for Claude" "" "$OUT4"
expect "strict hook: card unchanged" "$SUM4" "$(cksum < "$W50/.harness/gates/G-T050-4.md")"
expect "strict hook: no commit in the worktree (assets not committed)" "$HEAD4" "$(git -C "$W50" rev-parse HEAD)"
expect "strict hook: no push" 0 "$(grep -c . "$T/remote.log")"
expect "strict hook: no issue mapping" none "$(LIBPY 'print(H.read_issue(R, "G-T050-4") or "none")' || echo ERR)"
mkhookgate G-T050-5
runhook G-T050-5 HARNESS_FAKE_CLAUDE=1 > /dev/null
expect "standard hook: still publishes (1 issue create)" 1 "$(calls 'a[:2] == ["issue", "create"]')"
expect "standard hook: issue mapping recorded" 1 "$(LIBPY 'print(H.read_issue(R, "G-T050-5"))' || echo ERR)"

# ================================================================ 接续（gate_github.start_run）也用 strict goal
printf '#!/usr/bin/env bash\n[ "${1:-}" = --settings ] && shift 2\nprintf "%%s" "$2" > "%s/resume-goal"\n' "$T" > "$T/bin/claude-rec"; chmod +x "$T/bin/claude-rec"
(cd "$RC" && HARNESS_CLAUDE="$T/bin/claude-rec" $PY -c 'import sys; sys.path.insert(0, ".claude/hooks"); from pathlib import Path; import gate_github as G; G.start_run(Path(sys.argv[1]), Path(sys.argv[2]), "T-050", "人工门 G-T050-1 已答复：A", lambda *a: None)' "$RC" "$W50" >/dev/null 2>&1)
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/resume-goal" ] && break; sleep 0.3; done
expect "start_run: resumed goal is strict (不推送 + 不开 PR)" yes \
  "$(grep -qF '不推送' "$T/resume-goal" 2>/dev/null && grep -qF '不开 PR' "$T/resume-goal" && echo yes || echo no)"

# ================================================================ 控制路径命中的任务：调度器不推、不开 PR；Claude 侧仍为 0
cd "$RC" || exit 1
mkcard T-051 "src/T051/**"; git add -A && git commit -qm "add T-051"
export FAKEGH_DIR="$T/gh3"; mkdir -p "$FAKEGH_DIR"; : > "$FAKEGH_DIR/calls.jsonl"; : > "$T/remote.log"; : > "$T/git.log"
HARNESS_CLAUDE="$T/bin/claude-pub" scripts/harness-loop.sh --max-tasks 1 --no-groom --no-replan > "$T/loop51.out" 2>&1
expect "ctl task: fake claude ran for T-051" yes "$([ -f "$T/claude/goal.T-051" ] && echo yes || echo no)"
expect "ctl task: T-051 blocked" 1 "$(grep -c '^- T-051 | blocked' .harness/backlog.md)"
expect "ctl task: task/T-051-x not on the remote" no \
  "$([ -n "$(git --git-dir="$ORIGIN" branch --list 'task/T-051-x')" ] && echo yes || echo no)"
expect "ctl task: no ref update at all" 0 "$(grep -c . "$T/remote.log")"
expect "ctl task: no gh pr create" 0 "$(calls 'a[:2] == ["pr", "create"]')"
expect "ctl task: no PR mapping for G-T051-merge" None "$(LIBPY 'print(H.read_pr(R, "G-T051-merge"))' || echo ERR)"
expect "ctl task: 0 gh writes from claude" 0 "$(calls 'c["claude"] == "1" and c["write"]')"

# ################################################################ 接口约定 v2（挑错第 1 轮）
NOW="$(date +%s)"; LATER=$((NOW + 8 * 86400))
newrepo() {  # newrepo <名字> <TID…> —— 新仓库 + 裸远端（ref 更新记进 $RC.remote.log；有 $RC.refuse 时拒绝 task/*）+ 独立假 gh
  RC="$T/$1"; shift; mkdir -p "$RC" && cd "$RC" || exit 1
  git init -q -b main && git config user.email t@t && git config user.name t
  git config commit.gpgsign false; git config push.negotiate false
  cp -R "$SRC/CLAUDE.md" "$SRC/.claude" "$SRC/.harness" "$SRC/scripts" .
  rm -rf .claude/worktrees .harness/logs; rm -f .harness/gates/G-*.md
  printf '.claude/worktrees/\n.harness/logs/\n__pycache__/\n' > .gitignore
  sed -i.bak '/^- T-001 /d' .harness/backlog.md; rm -f .harness/backlog.md.bak
  local t; for t in "$@"; do mkcard "$t" "src/${t//-/}/**"; done
  git add -A && git commit -qm init
  ORIGIN="$RC.origin.git"; git init -q --bare "$ORIGIN"; git remote add origin "$ORIGIN"; git push -q origin main 2>/dev/null
  printf '#!/bin/sh\n[ -f "%s.refuse" ] && case "$1" in refs/heads/task/*) exit 1;; esac\necho "$1 $2 $3 claude=${HARNESS_FAKE_CLAUDE:-}" >> "%s.remote.log"\n' "$RC" "$RC" > "$ORIGIN/hooks/update"
  chmod +x "$ORIGIN/hooks/update"; : > "$RC.remote.log"
  export FAKEGH_DIR="$RC.gh"; mkdir -p "$FAKEGH_DIR"; : > "$FAKEGH_DIR/calls.jsonl"; rm -f "$FAKEGH_DIR/state.json"
}
runloop() { HARNESS_CLAUDE="$T/bin/claude-pub" scripts/harness-loop.sh --max-tasks 1 --no-groom --no-replan "$@" > "$RC.loop.out" 2>&1; }
gsync() { scripts/gate-sync.sh "$@" >> "$RC.gs.out" 2>&1; }
seedprs() { printf '{"issues": [], "labels": [], "prs": %s}\n' "$1" > "$FAKEGH_DIR/state.json"; }
prof() { ghstate "print(next((p['number'] for p in s['prs'] if p['head'] == '$1' and p['state'] == 'OPEN'), 'none'))" || echo none; }
issues_for() { calls "a[:2] == ['issue', 'create'] and '$1' in (a[a.index('--title') + 1] if '--title' in a else '')"; }
st_of() { LIBPY "print(H.gate_state(R, '$1'))" || echo ERR; }
gb() {  # gb <command> -> allow|deny|ask（guard_bash，PreToolUse Bash）
  local o
  o=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$RC" "$1" \
      | python3 "$RC/.claude/hooks/guard_bash.py")
  [ -z "$o" ] && { echo allow; return; }
  python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])' <<<"$o" 2>/dev/null || echo ERR
}

# ---- (1) 没有写 PR 映射的 CLI；guard 拦写映射的调用；调度器不信先前伪造的映射（PR 的 headRefName 不是任务分支）
newrepo v2-forged T-050
OUTW="$($PY .claude/hooks/harness_lib.py merge-pr T-050 7 2>&1)"; RCW=$?
expect "v2(1) CLI 'merge-pr T-050 7' does not record (exit != 0)" "nonzero None" \
  "$([ "$RCW" -ne 0 ] && echo nonzero || echo zero) $(LIBPY 'print(H.read_pr(R, "G-T050-merge"))' || echo ERR)"
expect "v2(1) guard denies harness_lib.py merge-pr <T> <N>" deny "$(gb 'python3 .claude/hooks/harness_lib.py merge-pr T-050 7')"
expect "v2(1) guard denies a call to record_merge_pr" deny \
  "$(gb "python3 -c 'import sys; sys.path.insert(0, \".claude/hooks\"); import harness_lib as H; H.record_merge_pr(H.Path(\".\"), \"T-050\", 7)'")"
expect "v2(1) guard denies merge-pr even via .harness/lib" deny "$(gb 'python3 .harness/lib/harness_lib.py merge-pr T-050 7')"
seedprs '[{"number": 7, "head": "evil", "base": "main", "state": "MERGED", "author": "me", "title": "x", "body": "", "comments": [], "labels": []}]'
LIBPY 'H.record_pr(R, "G-T050-merge", 7)' >/dev/null   # 先前（standard 会话里）伪造的映射：PR #7 不是 T-050 的分支
runloop; gsync
NEWPR="$(prof task/T-050-x)"
expect "v2(1) forged mapping: scheduler still opens 1 PR for task/T-050-x" 1 "$(calls 'a[:2] == ["pr", "create"] and "task/T-050-x" in a')"
expect "v2(1) forged mapping: merge gate now mapped to the new PR (not #7)" "$NEWPR" "$(LIBPY 'print(H.read_pr(R, "G-T050-merge"))' || echo ERR)"
expect "v2(1) forged mapping: merged PR #7 does not approve the merge gate" open "$(st_of G-T050-merge)"

# ---- (4) 恢复：pr create 失败时只认控制面自己开的、head 是任务分支的 OPEN PR；已关闭的映射 → 开新 PR
newrepo v2-closed T-050
seedprs '[{"number": 7, "head": "task/T-050-x", "base": "main", "state": "CLOSED", "author": "me", "title": "x", "body": "", "comments": [], "labels": []}]'
LIBPY 'H.record_pr(R, "G-T050-merge", 7)' >/dev/null
runloop
expect "v2(4) recorded PR closed: a new PR is opened" 1 "$(calls 'a[:2] == ["pr", "create"] and "task/T-050-x" in a')"
expect "v2(4) recorded PR closed: mapping moves to the new PR" "$(prof task/T-050-x)" "$(LIBPY 'print(H.read_pr(R, "G-T050-merge"))' || echo ERR)"
expect "v2(4) recorded PR closed: new PR number is not 7" yes "$([ "$(prof task/T-050-x)" != 7 ] && [ "$(prof task/T-050-x)" != none ] && echo yes || echo no)"

newrepo v2-ours T-050
seedprs '[{"number": 7, "head": "task/T-050-x", "base": "main", "state": "OPEN", "author": "me", "title": "x", "body": "", "comments": [], "labels": []}]'
runloop
expect "v2(4) pr create fails (PR exists): looks up gh pr list --head task/T-050-x" yes \
  "$([ "$(calls 'a[:2] == ["pr", "list"] and "--head" in a and a[a.index("--head") + 1] == "task/T-050-x"')" -ge 1 ] && echo yes || echo no)"
expect "v2(4) existing open PR by the control plane is recorded" 7 "$(LIBPY 'print(H.read_pr(R, "G-T050-merge"))' || echo ERR)"
expect "v2(4) task stays review" 1 "$(grep -c '^- T-050 | review' .harness/backlog.md)"

newrepo v2-theirs T-050
seedprs '[{"number": 7, "head": "task/T-050-x", "base": "main", "state": "OPEN", "author": "mallory", "title": "x", "body": "", "comments": [], "labels": []}]'
runloop
expect "v2(4) existing open PR by someone else: not recorded" None "$(LIBPY 'print(H.read_pr(R, "G-T050-merge"))' || echo ERR)"
expect "v2(4) someone else's PR: task stays review" 1 "$(grep -c '^- T-050 | review' .harness/backlog.md)"

# ---- (5) 推送失败 / 开 PR 失败：保持 review，什么都不记
newrepo v2-pushfail T-050
touch "$RC.refuse"; runloop
expect "v2(5) push refused: task branch not on the remote" no "$([ -n "$(git --git-dir="$ORIGIN" branch --list 'task/T-050-x')" ] && echo yes || echo no)"
expect "v2(5) push refused: no gh pr create" 0 "$(calls 'a[:2] == ["pr", "create"]')"
expect "v2(5) push refused: nothing recorded" None "$(LIBPY 'print(H.read_pr(R, "G-T050-merge"))' || echo ERR)"
expect "v2(5) push refused: task stays review" 1 "$(grep -c '^- T-050 | review' .harness/backlog.md)"
newrepo v2-prfail T-050
FAKEGH_FAIL="pr create" runloop
expect "v2(5) pr create fails (no PR anywhere): nothing recorded" None "$(LIBPY 'print(H.read_pr(R, "G-T050-merge"))' || echo ERR)"
expect "v2(5) pr create fails: task stays review" 1 "$(grep -c '^- T-050 | review' .harness/backlog.md)"
expect "v2(5) pr create fails: 0 gh writes from claude" 0 "$(calls 'c["claude"] == "1" and c["write"]')"

# ---- (5) 整合模式不变：不推任务分支、不开任务 PR；只推整合分支、开 1 个整合 PR
newrepo v2-integ T-050
printf '#!/usr/bin/env bash\nexit 0\n' > .harness/verify.sh; chmod +x .harness/verify.sh; git add -A && git commit -qm verify
runloop --integration
expect "v2(5) integration: task integrated" 1 "$(grep -c '^- T-050 | integrated' .harness/backlog.md)"
expect "v2(5) integration: no task-branch push" 0 "$(grep -c 'refs/heads/task/' "$RC.remote.log")"
expect "v2(5) integration: integration branch pushed once" 1 "$(grep -c 'refs/heads/integration/' "$RC.remote.log")"
expect "v2(5) integration: no per-task PR" 0 "$(calls 'a[:2] == ["pr", "create"] and any(x.startswith("task/") for x in a)')"
expect "v2(5) integration: exactly 1 integration PR" 1 "$(calls 'a[:2] == ["pr", "create"] and any(x.startswith("integration/") for x in a)')"
expect "v2(5) integration: 0 gh writes from claude" 0 "$(calls 'c["claude"] == "1" and c["write"]')"

# ---- (5) 合并门卡永不自动决定（即使 Claude 把草稿 kind 写成已放权的类别）
newrepo v2-auto T-050
printf 'ui\n' > .harness/auto-decide.txt; git add -A && git commit -qm auto
FAKECL_MERGE_KIND=ui runloop; gsync; gsync
expect "v2(5) merge gate (kind ui, ui delegated) not auto-answered" open "$(st_of G-T050-merge)"
expect "v2(5) merge gate still attached to its PR" yes \
  "$(ghstate 'print("yes" if any("G-T050-merge" in c for p in s["prs"] for c in p["comments"]) else "no")' || echo no)"

# ---- (7) 调度器写合并门卡草稿：原子替换，不顺着符号链接写到仓库外
newrepo v2-draft T-050
mkdir -p .harness/gates; ln -s "$T/v2-draft-outside.md" .harness/gates/G-T050-merge.md   # 悬空符号链接
FAKECL_NO_MERGE=1 runloop
DR="$RC/.harness/gates/G-T050-merge.md"
expect "v2(7) draft not written through a symlink (outside file absent)" no "$([ -e "$T/v2-draft-outside.md" ] && echo yes || echo no)"
expect "v2(7) draft is a regular file in the main checkout" yes "$([ -f "$DR" ] && [ ! -L "$DR" ] && echo yes || echo no)"
expect "v2(7) draft kind irreversible" irreversible "$(sed -n 's/^kind:[[:space:]]*\([a-z]*\).*/\1/p' "$DR" 2>/dev/null | head -n1)"
expect "v2(7) draft mapped to the PR" "$(prof task/T-050-x)" "$(LIBPY 'print(H.read_pr(R, "G-T050-merge"))' || echo ERR)"
expect "v2(7) no temp files left next to the draft" "" "$(ls -A "$RC/.harness/gates" | grep -v -e '^_TEMPLATE\.md$' -e '^G-T050-merge\.md$')"

# ---- (2) 发布认领：<GID>.pubclaim.json（O_EXCL）在 gh issue create 之前；并发的两个发布者只开 1 个 Issue
newrepo v2-claim T-050 T-052
runloop   # T-050 strict 跑过：G-T050-1 由 gate-sync 发布
expect "v2(2) setup: G-T050-1 unpublished after the loop" 0 "$(issues_for G-T050-1)"
( FAKEGH_DELAY_ISSUE=1.5 scripts/gate-sync.sh >/dev/null 2>&1 & FAKEGH_DELAY_ISSUE=1.5 scripts/gate-sync.sh >/dev/null 2>&1 & wait )
expect "v2(2) two concurrent gate-syncs: 1 issue for G-T050-1" 1 "$(issues_for G-T050-1)"
expect "v2(2) pubclaim recorded for G-T050-1" True "$(LIBPY 'print((H.answers_dir(R) / "G-T050-1.pubclaim.json").is_file())' || echo ERR)"
scripts/new-task.sh T-052 >/dev/null 2>&1; W52="$RC/.claude/worktrees/T-052"   # 从没 strict 启动过的 checkout：hook 照旧发布
mk52() { sed -e "s/G-T000-1/$1/g" -e 's/^task: T-000/task: T-052/' "$W52/.harness/gates/_TEMPLATE.md" > "$W52/.harness/gates/$1.md"; }
hook52() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' \
  "$W52" "$W52/.harness/gates/$1.md" | (cd "$W52" && python3 .claude/hooks/gate_github.py hook >/dev/null 2>&1); }
mk52 G-T052-1
( cd "$W52" && { FAKEGH_DELAY_ISSUE=1.5 hook52 G-T052-1 & FAKEGH_DELAY_ISSUE=1.5 python3 .claude/hooks/gate_github.py publish "$W52/.harness/gates/G-T052-1.md" >/dev/null 2>&1 & wait; } )
expect "v2(2) concurrent hook + manual publish: 1 issue for G-T052-1" 1 "$(issues_for G-T052-1)"
mk52 G-T052-2
LIBPY 'H._create_json(H.answers_dir(R, create=True) / "G-T052-2.pubclaim.json", {"gid": "G-T052-2", "at": H._now()})' >/dev/null
hook52 G-T052-2
expect "v2(2) an existing claim stops the hook from creating an issue" 0 "$(issues_for G-T052-2)"
mk52 G-T052-3
gsync; gsync
expect "v2(5) never-launched (standard) checkout: gate-sync does not publish its unhooked gate" 0 "$(issues_for G-T052-3)"

# ---- (3) strict 启动判定：也认 strict-settings.json（不带 --task 的 strict 启动），按 checkout；
#          之后在同一 checkout 做过 standard 启动、或超过 7 天（HARNESS_NOW）就不算
newrepo v2-launch T-060 T-061
scripts/new-task.sh T-060 >/dev/null 2>&1; scripts/new-task.sh T-061 >/dev/null 2>&1
W60="$RC/.claude/worktrees/T-060"; W61="$RC/.claude/worktrees/T-061"
cat > "$T/bin/claude-gate" <<'SH'
#!/usr/bin/env bash
export HARNESS_FAKE_CLAUDE=1
[ "${1:-}" = --settings ] && shift 2
T0="$(git branch --show-current | grep -o 'T-[0-9]*')"
sed -e "s/G-T000-1/$FAKECL_GATE/g" -e "s/^task: T-000/task: $T0/" .harness/gates/_TEMPLATE.md > ".harness/gates/$FAKECL_GATE.md"
python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' \
  "$(pwd)" "$(pwd)/.harness/gates/$FAKECL_GATE.md" | python3 .claude/hooks/gate_github.py hook >/dev/null 2>&1
exit 0
SH
chmod +x "$T/bin/claude-gate"
L() { HARNESS_CLAUDE="$T/bin/claude-gate" $PY "$RC/.claude/hooks/harness_lib.py" launch "$@" >/dev/null 2>&1; }
FAKECL_GATE=G-T060-1 L --strict --root "$W60" -- -p x
expect "v2(3) setup: interactive strict launch wrote strict-settings.json" True "$(LIBPY 'print((H.state_dir(R) / "strict-settings.json").is_file())' || echo ERR)"
expect "v2(3) strict hook did not publish G-T060-1" 0 "$(issues_for G-T060-1)"
gsync
expect "v2(3) strict-settings.json honoured: gate-sync publishes G-T060-1 (control plane)" 1 \
  "$(calls "a[:2] == ['issue', 'create'] and c['claude'] == '' and 'G-T060-1' in a[a.index('--title') + 1]")"
FAKECL_GATE=G-T060-2 L --root "$W60" -- -p x        # 同一 checkout 之后的 standard 启动：hook 照旧发布
expect "v2(3) later standard launch: hook publishes G-T060-2" 1 "$(issues_for G-T060-2)"
mk60() { sed -e "s/G-T000-1/$1/g" -e 's/^task: T-000/task: T-060/' "$W60/.harness/gates/_TEMPLATE.md" > "$W60/.harness/gates/$1.md"; }
mk60 G-T060-3; gsync
expect "v2(3) strict file older than the checkout's last (standard) launch: unhooked G-T060-3 not published" 0 "$(issues_for G-T060-3)"
FAKECL_GATE=G-T061-1 L --strict --root "$W61" -- -p x   # 另一个 checkout 的 strict 启动不影响 T-060 的判定
mk60 G-T060-4
HARNESS_NOW="$LATER" gsync
expect "v2(3) strict launch older than 7 days (HARNESS_NOW): G-T061-1 not published" 0 "$(issues_for G-T061-1)"
gsync
expect "v2(3) fresh strict launch of T-061: G-T061-1 published" 1 "$(issues_for G-T061-1)"
expect "v2(3) per checkout: T-061's strict launch does not make T-060 strict again (G-T060-4)" 0 "$(issues_for G-T060-4)"

# ---- (3) 调度器自己的门卡（-ctl / -merge）不看 strict 判定，gate-sync 总会发布
cd "$T/repo" || exit 1; RC="$T/repo"; export FAKEGH_DIR="$T/gh3"
LIBPY 'import os
for f in H.state_dir(R).glob("strict-settings*.json"): os.remove(f)' >/dev/null
HARNESS_NOW="$LATER" scripts/gate-sync.sh > "$T/gs-ctl1.out" 2>&1; N1="$(issues_for G-T051-ctl)"
HARNESS_NOW="$LATER" scripts/gate-sync.sh > "$T/gs-ctl2.out" 2>&1
expect "v2(3) G-T051-ctl published by gate-sync without any strict-settings file" 1 "$N1"
expect "v2(5) second gate-sync does not republish G-T051-ctl" 1 "$(issues_for G-T051-ctl)"
expect "v2(3) G-T051-ctl issue not from claude" 0 "$(calls "a[:2] == ['issue', 'create'] and c['claude'] == '1'")"
expect "v2(3) merge gate without a PR (blocked T-051) still not published" 0 "$(issues_for G-T051-merge)"

echo "$((N - FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
