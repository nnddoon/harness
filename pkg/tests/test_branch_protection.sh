#!/usr/bin/env bash
# T-014 验收（S-002#18、#12）：init / setup 检查分支保护；能开 → 开 external 门卡，开不了 → 一句话说明；
# 任何情形下对 GitHub 的写调用为 0。假 gh：tests/fake/gh（按 $FAKEGH_CASE 回答，调用记到 $FAKEGH_LOG）。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-bp.XXXXXX")"; trap 'rm -rf "$T"' EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
yn() { if eval "$1"; then echo yes; else echo no; fi; }

# 真 gh 永远不许被碰到：PATH 里放一个陷阱 gh；实现必须只用 $HARNESS_GH
mkdir -p "$T/pathbin"
printf '#!/bin/sh\necho "$@" >> "%s/path-gh.log"\nexit 1\n' "$T" > "$T/pathbin/gh"; chmod +x "$T/pathbin/gh"
export PATH="$T/pathbin:$PATH"
FAKE="$SRC/tests/fake/gh"; chmod +x "$FAKE" 2>/dev/null
unset GH_TOKEN GITHUB_TOKEN GH_HOST
GATE=.harness/gates/G-SETUP-bp.md
PUT_BP='gh api -X PUT repos/acme/widget/branches/trunk/protection'
PUT_WF='gh api -X PUT repos/acme/widget/actions/permissions/workflow -f default_workflow_permissions=read'

# 写调用 = 非 GET 的 api（含带字段而默认 POST 的）、或 auth status / repo view / api 之外的任何子命令
writes() {
  python3 - "$1" <<'PY'
import json, sys
n = 0
try:
    lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
except OSError:
    lines = []
for l in lines:
    a = json.loads(l)["argv"]
    if a[:2] in (["auth", "status"], ["repo", "view"]):
        continue
    if a[:1] != ["api"]:
        n += 1; continue
    m = "GET"
    for f in ("-X", "--method"):
        if f in a:
            m = a[a.index(f) + 1].upper()
    if "-X" not in a and "--method" not in a and any(x in a for x in ("-f", "-F", "--field", "--raw-field", "--input")):
        m = "POST"
    n += m != "GET"
print(n)
PY
}
calls() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
bplines() { printf '%s\n' "$1" | grep -c '分支保护'; }
fm() { python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import harness_lib as H, pathlib; print(H.read_frontmatter(pathlib.Path(sys.argv[2])).get(sys.argv[3], ""))' "$1/.claude/hooks" "$1/$GATE" "$2" 2>/dev/null; }
cmdline() { grep -F -- "$2" "$1/$GATE" 2>/dev/null | head -1; }

newrepo() {  # newrepo <name> [noremote]
  local r="$T/$1"; mkdir -p "$r" && cd "$r" && git init -q -b main && git config user.email t@t && git config user.name t
  [ "${2:-}" = noremote ] || git remote add origin https://github.com/acme/widget.git
  printf '[project]\nname = "demo"\n' > pyproject.toml
  echo "$r"
}
# run <case> <repo> [init args...] → 设 OUT / RC / LOG
run() {
  local c="$1" r="$2"; shift 2
  LOG="$T/$c.$(basename "$r").log"
  OUT="$(cd "$r" && FAKEGH_CASE="$c" FAKEGH_LOG="$LOG" HARNESS_GH="${GHBIN:-$FAKE}" python3 "$SRC/bin/harness" init "$@" --target "$r" 2>&1)"; RC=$?
}

# ---------------------------------------------------------------- a. 公开仓库，未开保护（404）→ 开门卡
R="$(newrepo pub)"; run public "$R" --yes
expect "public: init exits 0" 0 "$RC"
expect "public: gh was actually asked (repo view)" yes "$(yn "grep -q '\"repo\", \"view\"' '$LOG'")"
expect "public: protection endpoint read for the real default branch" yes "$(yn "grep -qF 'repos/acme/widget/branches/trunk/protection' '$LOG'")"
expect "public: zero write calls" 0 "$(writes "$LOG")"
expect "public: gate card written" yes "$(yn "[ -f '$R/$GATE' ]")"
expect "public: gate id" G-SETUP-bp "$(fm "$R" id)"
expect "public: gate kind external" external "$(fm "$R" kind)"
expect "public: gate status open" open "$(fm "$R" status)"
expect "public: approve_options = A" "['A']" "$(fm "$R" approve_options)"
L="$(cmdline "$R" "$PUT_BP")"
expect "public: card has the PUT protection command (owner/repo/branch from gh)" yes "$(yn '[ -n "$L" ]')"
for k in 'enforce_admins=true' 'required_pull_request_reviews[required_approving_review_count]=1' \
         'allow_force_pushes=false' 'allow_deletions=false' 'required_status_checks=null' 'restrictions=null'; do
  expect "public: protection command sets $k" yes "$(yn 'printf "%s" "$L" | grep -qF -- "$k"')"
done
expect "public: card has the Actions read-only command" yes "$(yn "grep -qxF -- '$PUT_WF' '$R/$GATE' || grep -qF -- '$PUT_WF' '$R/$GATE'")"
expect "public: card does not hardcode main" no "$(yn "grep -qF 'branches/main/' '$R/$GATE'")"
expect "public: exactly one branch-protection line" 1 "$(bplines "$OUT")"
expect "public: that line points to the gate card" yes "$(yn 'printf "%s\n" "$OUT" | grep "分支保护" | grep -qF "$GATE"')"
expect "public: real gh on PATH never used" no "$(yn "[ -e '$T/path-gh.log' ]")"
# 重跑：门卡已存在 → 不覆盖、不新开
printf '\n<!-- 我的备注 -->\n' >> "$R/$GATE"; cp "$R/$GATE" "$T/gate.before"
run public "$R" --yes
expect "public rerun: init exits 0" 0 "$RC"
expect "public rerun: existing gate card untouched" yes "$(yn "cmp -s '$T/gate.before' '$R/$GATE'")"
expect "public rerun: still only one setup gate" 1 "$(ls "$R"/.harness/gates/G-SETUP* 2>/dev/null | wc -l | tr -d ' ')"
expect "public rerun: zero write calls" 0 "$(writes "$LOG")"

# ---------------------------------------------------------------- a'. 私有仓库 + Pro/Team（404）→ 同样开门卡
R="$(newrepo pro)"; run pro "$R" --yes
expect "private+pro: init exits 0" 0 "$RC"
expect "private+pro: zero write calls" 0 "$(writes "$LOG")"
expect "private+pro: gate card written" external "$(fm "$R" kind)"
expect "private+pro: card has the PUT protection command" yes "$(yn '[ -n "$(cmdline "$R" "$PUT_BP")" ]')"
expect "private+pro: card has the Actions read-only command" yes "$(yn "grep -qF -- '$PUT_WF' '$R/$GATE'")"
expect "private+pro: no 'cannot' message" no "$(yn 'printf "%s" "$OUT" | grep -q "Pro/Team"')"

# ---------------------------------------------------------------- b. 私有仓库 + Free（403 升级 Pro）→ 一句话，不开门卡
R="$(newrepo free)"; run free "$R" --yes
expect "private+free: init exits 0" 0 "$RC"
expect "private+free: zero write calls" 0 "$(writes "$LOG")"
expect "private+free: no gate card" no "$(yn "[ -e '$R/$GATE' ]")"
expect "private+free: exactly one branch-protection line" 1 "$(bplines "$OUT")"
expect "private+free: says it needs Pro/Team" yes "$(yn 'printf "%s\n" "$OUT" | grep "分支保护" | grep -q "Pro/Team"')"
expect "private+free: says strict mode still blocks locally" yes "$(yn 'printf "%s\n" "$OUT" | grep "分支保护" | grep -q "strict 模式已在本机挡住"')"
expect "private+free: not reported as a skip" no "$(yn 'printf "%s" "$OUT" | grep -q "跳过分支保护检查"')"

# ---------------------------------------------------------------- 已开保护（200）→ ✓，不开门卡
R="$(newrepo prot)"; run protected "$R" --yes
expect "protected: init exits 0" 0 "$RC"
expect "protected: zero write calls" 0 "$(writes "$LOG")"
expect "protected: no gate card" no "$(yn "[ -e '$R/$GATE' ]")"
expect "protected: exactly one branch-protection line" 1 "$(bplines "$OUT")"
expect "protected: ✓ line names repo and branch" yes "$(yn 'printf "%s\n" "$OUT" | grep "✓ 分支保护已开启" | grep -q "acme/widget.*trunk"')"

# ---------------------------------------------------------------- c. 无法检查 → 跳过，一行原因，init 照常 0
for c in unauthed noremote noadmin missing; do
  if [ "$c" = noremote ]; then R="$(newrepo "c-$c" noremote)"; else R="$(newrepo "c-$c")"; fi
  if [ "$c" = missing ]; then GHBIN="$T/no-such-dir/gh" run public "$R" --yes; else run "$c" "$R" --yes; fi
  expect "skip ($c): init exits 0" 0 "$RC"
  expect "skip ($c): install still happened" yes "$(yn "[ -f '$R/.harness/verify.sh' ]")"
  expect "skip ($c): zero write calls" 0 "$(writes "$LOG")"
  expect "skip ($c): no gate card" no "$(yn "[ -e '$R/$GATE' ]")"
  expect "skip ($c): exactly one branch-protection line" 1 "$(bplines "$OUT")"
  expect "skip ($c): line starts with 跳过分支保护检查：" yes "$(yn 'printf "%s\n" "$OUT" | grep -q "^跳过分支保护检查："')"
  [ "$c" = noadmin ] && expect "skip (noadmin): a non-plan 403 is not called a plan limit" no "$(yn 'printf "%s" "$OUT" | grep -q "Pro/Team"')"
done
expect "gh missing: no fallback to gh on PATH" no "$(yn "[ -e '$T/path-gh.log' ]")"

# ---------------------------------------------------------------- dry-run：说会做什么，不写任何东西
R="$(newrepo dry)"; run public "$R" --dry-run
expect "dry-run: exits 0" 0 "$RC"
expect "dry-run: zero write calls" 0 "$(writes "$LOG")"
expect "dry-run: did the read-only check" yes "$(yn "grep -qF 'branches/trunk/protection' '$LOG'")"
expect "dry-run: says it would open G-SETUP-bp" yes "$(yn 'printf "%s" "$OUT" | grep -q "G-SETUP-bp"')"
expect "dry-run: no gate card" no "$(yn "[ -e '$R/$GATE' ]")"
expect "dry-run: nothing written at all" "" "$(cd "$R" && git status --porcelain --untracked-files=all | grep -v '^?? pyproject.toml$')"
R="$(newrepo dryfree)"; run free "$R" --dry-run
expect "dry-run free: explains Pro/Team, writes nothing" "yes 0" "$(yn 'printf "%s" "$OUT" | grep -q "Pro/Team"') $(writes "$LOG")"

# ---------------------------------------------------------------- 插件模式（/harness:setup）同样检查
R="$(newrepo plug)"; run public "$R" --plugin --yes
expect "plugin: init exits 0" 0 "$RC"
expect "plugin: zero write calls" 0 "$(writes "$LOG")"
expect "plugin: gate card written" yes "$(yn "[ -f '$R/$GATE' ] && grep -qF -- '$PUT_BP' '$R/$GATE'")"
expect "plugin: exactly one branch-protection line" 1 "$(bplines "$OUT")"
expect "setup skill tells the user about branch protection" yes "$(yn "grep -q '分支保护' '$SRC/plugin/skills/setup/SKILL.md'")"
expect "real gh on PATH never used in any case" no "$(yn "[ -e '$T/path-gh.log' ]")"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
