#!/usr/bin/env bash
# T-014 验收（S-002#18、#12）：init / setup 检查分支保护；能开 → 开 external 门卡，开不了 → 一句话说明；
# 任何情形下对 GitHub 只有白名单里的只读调用。假 gh：tests/fake/gh（按 $FAKEGH_CASE 回答，调用记到 $FAKEGH_LOG）。
# 接口约定见任务卡 T-014「接口约定」与「接口约定 v2」。
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
unset GH_TOKEN GITHUB_TOKEN GH_HOST GH_ENTERPRISE_TOKEN
GATE=.harness/gates/G-SETUP-bp.md
PUT_BP='gh api --hostname github.com -X PUT repos/acme/widget/branches/trunk/protection'
PUT_WF='gh api --hostname github.com -X PUT repos/acme/widget/actions/permissions/workflow -f default_workflow_permissions=read'

# 白名单外的调用数（argv 逐字比较）。offlist <log> [host] [branch]
offlist() {
  python3 - "$1" "${2:-github.com}" "${3:-trunk}" <<'PY'
import json, sys
from urllib.parse import quote
log, h, b = sys.argv[1:4]
allowed = {("repo", "view", "--json", "url,visibility,owner,nameWithOwner,defaultBranchRef"),
           ("api", "--hostname", h, f"repos/acme/widget/branches/{quote(b, safe='')}/protection"),
           ("api", "--hostname", h, "repos/acme/widget/actions/permissions/workflow")}
try:
    lines = open(log, encoding="utf-8").read().splitlines()
except OSError:
    lines = []
print(sum(tuple(json.loads(l)["argv"]) not in allowed for l in lines))
PY
}
called() { [ -f "$1" ] || { echo 0; return; }; grep -cF -- "$2" "$1" || true; }  # called <log> <substring of the JSON argv>
WFGET='"repos/acme/widget/actions/permissions/workflow"'
bplines() { printf '%s\n' "$1" | grep -c '分支保护'; }
bpline() { printf '%s\n' "$1" | grep '分支保护' | head -1; }
fm() { python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import harness_lib as H, pathlib; print(H.read_frontmatter(pathlib.Path(sys.argv[2])).get(sys.argv[3], ""))' "$1/.claude/hooks" "$1/$GATE" "$2" 2>/dev/null; }
cmdline() { grep -F -- "$2" "$1/$GATE" 2>/dev/null | head -1; }
prose() { awk '/^```/{f=!f; next} !f' "$1/$GATE" 2>/dev/null; }  # 门卡里代码块之外的部分（含 frontmatter）

newrepo() {  # newrepo <name> [noremote]
  local r="$T/$1"; mkdir -p "$r" && cd "$r" && git init -q -b main && git config user.email t@t && git config user.name t
  [ "${2:-}" = noremote ] || git remote add origin https://github.com/acme/widget.git
  printf '[project]\nname = "demo"\n' > pyproject.toml
  echo "$r"
}
# run <case> <repo> [init args...] → 设 OUT / RC / LOG / SECS
run() {
  local c="$1" r="$2" t0; shift 2
  LOG="$T/$c.$(basename "$r").$RANDOM.log"; t0=$(date +%s)
  OUT="$(cd "$r" && FAKEGH_CASE="$c" FAKEGH_LOG="$LOG" HARNESS_GH="${GHBIN:-$FAKE}" python3 "$SRC/bin/harness" init "$@" --target "$r" 2>&1)"; RC=$?
  SECS=$(( $(date +%s) - t0 ))
}

# ---------------------------------------------------------------- 白名单检测器自检（v2#3）
printf '%s\n' '{"argv":["repo","view","--json","url,visibility,owner,nameWithOwner,defaultBranchRef"]}' \
  '{"argv":["api","--hostname","github.com","repos/acme/widget/branches/trunk/protection"]}' \
  '{"argv":["api","--hostname","github.com","repos/acme/widget/actions/permissions/workflow"]}' > "$T/det.ok"
expect "detector: allowlisted reads pass" 0 "$(offlist "$T/det.ok")"
printf '%s\n' '{"argv":["api","--hostname","github.com","-XPUT","repos/acme/widget/branches/trunk/protection"]}' \
  '{"argv":["api","--hostname","github.com","--method=PUT","repos/acme/widget/actions/permissions/workflow"]}' \
  '{"argv":["api","repos/acme/widget/branches/trunk/protection"]}' \
  '{"argv":["auth","status"]}' '{"argv":["repo","edit","--visibility","public"]}' > "$T/det.bad"
expect "detector: -XPUT, --method=PUT, missing --hostname, auth status, repo edit all caught" 5 "$(offlist "$T/det.bad")"

# ---------------------------------------------------------------- a. 公开仓库，未开保护（404）→ 开门卡
R="$(newrepo pub)"; run public "$R" --yes
expect "public: init exits 0" 0 "$RC"
expect "public: gh was actually asked (repo view)" yes "$(yn "grep -q '\"repo\", \"view\"' '$LOG'")"
expect "public: protection endpoint read for the real default branch" yes "$(yn "grep -qF 'repos/acme/widget/branches/trunk/protection' '$LOG'")"
expect "public: only allowlisted read calls (exact argv)" 0 "$(offlist "$LOG")"
expect "public: Actions workflow permissions read once" 1 "$(called "$LOG" "$WFGET")"
expect "public: gate card written" yes "$(yn "[ -f '$R/$GATE' ]")"
expect "public: gate id" G-SETUP-bp "$(fm "$R" id)"
expect "public: gate kind external" external "$(fm "$R" kind)"
expect "public: gate status open" open "$(fm "$R" status)"
expect "public: approve_options = A" "['A']" "$(fm "$R" approve_options)"
L="$(cmdline "$R" "$PUT_BP")"
expect "public: card has the PUT protection command with --hostname (owner/repo/branch from gh)" yes "$(yn '[ -n "$L" ]')"
for k in 'enforce_admins=true' 'required_pull_request_reviews[required_approving_review_count]=0' \
         'allow_force_pushes=false' 'allow_deletions=false' 'required_status_checks=null' 'restrictions=null'; do
  expect "public: protection command sets $k" yes "$(yn 'printf "%s" "$L" | grep -qF -- "$k"')"
done
expect "public: no review requirement that locks out a solo owner (=1)" no "$(yn 'printf "%s" "$L" | grep -qF "required_approving_review_count]=1"')"
OPTA="$(grep -E '^- \*\*A' "$R/$GATE" 2>/dev/null)"
expect "public: option A says PRs are still required" yes "$(yn 'printf "%s" "$OPTA" | grep -q "必须走 PR"')"
expect "public: option A says a solo owner can merge own PRs" yes "$(yn 'printf "%s" "$OPTA" | grep -q "一个人也能合并自己的 PR"')"
expect "public: card has the Actions read-only command (write → read)" yes "$(yn "grep -qF -- '$PUT_WF' '$R/$GATE'")"
expect "public: card warns rulesets may still protect" yes "$(yn "grep -q '规则集' '$R/$GATE'")"
expect "public: card does not hardcode main" no "$(yn "grep -qF 'branches/main/' '$R/$GATE'")"
expect "public: exactly one branch-protection line" 1 "$(bplines "$OUT")"
expect "public: that line points to the gate card" yes "$(yn 'bpline "$OUT" | grep -qF "$GATE"')"
expect "public: that line names acme/widget" yes "$(yn 'bpline "$OUT" | grep -qF "acme/widget"')"
expect "public: that line says the card was opened" yes "$(yn 'bpline "$OUT" | grep -q "已开门卡"')"
expect "public: Actions advice is in the card, not printed again" no "$(yn 'printf "%s" "$OUT" | grep -q "default_workflow_permissions"')"
expect "public: real gh on PATH never used" no "$(yn "[ -e '$T/path-gh.log' ]")"
# 重跑：门卡已存在 → 不覆盖、不新开、不说「已开门卡」，行里给出门卡当前 status
printf '\n<!-- 我的备注 -->\n' >> "$R/$GATE"; cp "$R/$GATE" "$T/gate.before"
run public "$R" --yes
expect "public rerun: init exits 0" 0 "$RC"
expect "public rerun: existing gate card untouched" yes "$(yn "cmp -s '$T/gate.before' '$R/$GATE'")"
expect "public rerun: still only one setup gate" 1 "$(ls "$R"/.harness/gates/G-SETUP* 2>/dev/null | wc -l | tr -d ' ')"
expect "public rerun: only allowlisted read calls" 0 "$(offlist "$LOG")"
expect "public rerun (open card): does not claim it opened a card" no "$(yn 'bpline "$OUT" | grep -q "已开门卡"')"
expect "public rerun (open card): line names the card and its status" yes "$(yn 'bpline "$OUT" | grep -qF "$GATE" && bpline "$OUT" | grep -q "open"')"
sed -i 's/^status: open.*/status: rejected/' "$R/$GATE"; cp "$R/$GATE" "$T/gate.before"
run public "$R" --yes
expect "public rerun (answered card): does not say 已开门卡" no "$(yn 'printf "%s" "$OUT" | grep -q "已开门卡"')"
expect "public rerun (answered card): line reports status rejected" yes "$(yn 'bpline "$OUT" | grep -q "rejected"')"
expect "public rerun (answered card): card untouched" yes "$(yn "cmp -s '$T/gate.before' '$R/$GATE'")"
expect "public rerun (answered card): exactly one branch-protection line" 1 "$(bplines "$OUT")"

# ---------------------------------------------------------------- a'. 私有仓库 + Pro/Team（404）→ 同样开门卡
R="$(newrepo pro)"; run pro "$R" --yes
expect "private+pro: init exits 0" 0 "$RC"
expect "private+pro: only allowlisted read calls" 0 "$(offlist "$LOG")"
expect "private+pro: Actions workflow permissions read" 1 "$(called "$LOG" "$WFGET")"
expect "private+pro: gate card written" external "$(fm "$R" kind)"
expect "private+pro: card has the PUT protection command" yes "$(yn '[ -n "$(cmdline "$R" "$PUT_BP")" ]')"
expect "private+pro: card has the Actions read-only command" yes "$(yn "grep -qF -- '$PUT_WF' '$R/$GATE'")"
expect "private+pro: no 'cannot' message" no "$(yn 'printf "%s" "$OUT" | grep -q "Pro/Team"')"
expect "private+pro: line names acme/widget" yes "$(yn 'bpline "$OUT" | grep -qF "acme/widget"')"

# ---------------------------------------------------------------- Actions 已是只读 → 门卡里不放那条命令
R="$(newrepo pubread)"; FAKEGH_WF=read run public "$R" --yes
expect "public, Actions already read: card written" yes "$(yn "[ -f '$R/$GATE' ]")"
expect "public, Actions already read: no workflow PUT in card" no "$(yn "grep -qF 'default_workflow_permissions=read' '$R/$GATE'")"
expect "public, Actions already read: no Actions line" no "$(yn 'printf "%s" "$OUT" | grep -q "Actions"')"

# ---------------------------------------------------------------- b. 私有仓库 + Free（403 升级 Pro）→ 一句话，不开门卡
R="$(newrepo free)"; run free "$R" --yes
expect "private+free: init exits 0" 0 "$RC"
expect "private+free: only allowlisted read calls" 0 "$(offlist "$LOG")"
expect "private+free: no gate card" no "$(yn "[ -e '$R/$GATE' ]")"
expect "private+free: exactly one branch-protection line" 1 "$(bplines "$OUT")"
expect "private+free: says it needs Pro/Team" yes "$(yn 'bpline "$OUT" | grep -q "Pro/Team"')"
expect "private+free: says strict mode still blocks locally" yes "$(yn 'bpline "$OUT" | grep -q "strict 模式已在本机挡住"')"
expect "private+free: line names acme/widget" yes "$(yn 'bpline "$OUT" | grep -qF "acme/widget"')"
expect "private+free: not reported as a skip" no "$(yn 'printf "%s" "$OUT" | grep -q "跳过分支保护检查"')"
expect "private+free: Actions permissions still read" 1 "$(called "$LOG" "$WFGET")"
expect "private+free: Actions read-only suggested in one line" 1 "$(printf '%s\n' "$OUT" | grep -cF -- "$PUT_WF")"
expect "private+free: Actions line is separate from the protection line" no "$(yn 'bpline "$OUT" | grep -qF "default_workflow_permissions"')"

# ---------------------------------------------------------------- 已开保护（200）且完整 → ✓，不开门卡；Actions 仍查
R="$(newrepo prot)"; run protected "$R" --yes
expect "protected: init exits 0" 0 "$RC"
expect "protected: only allowlisted read calls" 0 "$(offlist "$LOG")"
expect "protected: no gate card" no "$(yn "[ -e '$R/$GATE' ]")"
expect "protected: exactly one branch-protection line" 1 "$(bplines "$OUT")"
expect "protected: ✓ line names repo and branch" yes "$(yn 'printf "%s\n" "$OUT" | grep "✓ 分支保护已开启" | grep -q "acme/widget.*trunk"')"
expect "protected: not called incomplete" no "$(yn 'printf "%s" "$OUT" | grep -q "不完整"')"
expect "protected: Actions permissions still read" 1 "$(called "$LOG" "$WFGET")"
expect "protected: Actions read-only suggested in one line" 1 "$(printf '%s\n' "$OUT" | grep -cF -- "$PUT_WF")"
R="$(newrepo protread)"; FAKEGH_WF=read run protected "$R" --yes
expect "protected, Actions already read: no Actions line" no "$(yn 'printf "%s" "$OUT" | grep -q "default_workflow_permissions"')"

# ---------------------------------------------------------------- 已开但不完整（200，缺项）→ 说缺什么
R="$(newrepo weak)"; run protected_weak "$R" --yes
expect "weak: init exits 0" 0 "$RC"
expect "weak: only allowlisted read calls" 0 "$(offlist "$LOG")"
expect "weak: exactly one branch-protection line" 1 "$(bplines "$OUT")"
W="$(bpline "$OUT")"
expect "weak: not reported as fully protected" no "$(yn 'printf "%s" "$W" | grep -q "✓"')"
expect "weak: says incomplete, names acme/widget" yes "$(yn 'printf "%s" "$W" | grep -q "不完整" && printf "%s" "$W" | grep -qF "acme/widget"')"
expect "weak: names force pushes" yes "$(yn 'printf "%s" "$W" | grep -q "强推"')"
expect "weak: names PR requirement" yes "$(yn 'printf "%s" "$W" | grep -q "PR"')"
expect "weak: names admins" yes "$(yn 'printf "%s" "$W" | grep -q "管理员"')"
R="$(newrepo fp)"; run protected_fp "$R" --yes
W="$(bpline "$OUT")"
expect "force-push only: says incomplete and names force pushes" yes "$(yn 'printf "%s" "$W" | grep -q "不完整" && printf "%s" "$W" | grep -q "强推"')"
expect "force-push only: does not blame admins" no "$(yn 'printf "%s" "$W" | grep -q "管理员"')"
expect "force-push only: does not blame PR requirement" no "$(yn 'printf "%s" "$W" | grep -q "PR"')"

# ---------------------------------------------------------------- GHE：主机名取自 repo view 的 url
R="$(newrepo ghe)"; FAKEGH_HOST=ghe.corp.example run public "$R" --yes
expect "GHE: init exits 0" 0 "$RC"
expect "GHE: every api call carries --hostname ghe.corp.example (exact allowlist)" 0 "$(offlist "$LOG" ghe.corp.example)"
expect "GHE: gate card written (404 seen on the right host)" yes "$(yn "[ -f '$R/$GATE' ]")"
expect "GHE: protection command targets the GHE host" yes "$(yn "grep -qF 'gh api --hostname ghe.corp.example -X PUT repos/acme/widget/branches/trunk/protection' '$R/$GATE'")"
expect "GHE: Actions command targets the GHE host" yes "$(yn "grep -qF 'gh api --hostname ghe.corp.example -X PUT repos/acme/widget/actions/permissions/workflow -f default_workflow_permissions=read' '$R/$GATE'")"
expect "GHE: no command left pointing at github.com" no "$(yn "grep -qF 'hostname github.com' '$R/$GATE'")"

# ---------------------------------------------------------------- 分支名带 Markdown/HTML 特殊字符 → 门卡正文转义
BR='dev`x|<b>y<!--z'
QB="$(python3 -c 'import sys; from urllib.parse import quote; print(quote(sys.argv[1], safe=""))' "$BR")"
R="$(newrepo odd)"; FAKEGH_BRANCH="$BR" run public "$R" --yes
expect "odd branch: init exits 0" 0 "$RC"
expect "odd branch: only allowlisted read calls (percent-encoded path)" 0 "$(offlist "$LOG" github.com "$BR")"
expect "odd branch: gate card written" yes "$(yn "[ -f '$R/$GATE' ]")"
expect "odd branch: command uses the percent-encoded path" yes "$(yn "grep -qF 'repos/acme/widget/branches/$QB/protection' '$R/$GATE'")"
expect "odd branch: no raw <!-- outside code blocks" no "$(yn 'prose "$R" | grep -qF "<!--"')"
expect "odd branch: no raw <b> outside code blocks" no "$(yn 'prose "$R" | grep -qF "<b>"')"
expect "odd branch: raw branch name never in prose" no "$(yn 'prose "$R" | grep -qF -- "$BR"')"
expect "odd branch: prose shows it HTML-escaped" yes "$(yn 'prose "$R" | grep -qF "dev&#96;x&#124;&lt;b&gt;y&lt;!--z"')"
expect "odd branch: frontmatter still parses (id)" G-SETUP-bp "$(fm "$R" id)"

# ---------------------------------------------------------------- c. 无法检查 → 跳过，一行原因，init 照常 0
for c in unauthed noremote noadmin missing; do
  if [ "$c" = noremote ]; then R="$(newrepo "c-$c" noremote)"; else R="$(newrepo "c-$c")"; fi
  if [ "$c" = missing ]; then GHBIN="$T/no-such-dir/gh" run public "$R" --yes; else run "$c" "$R" --yes; fi
  expect "skip ($c): init exits 0" 0 "$RC"
  expect "skip ($c): install still happened" yes "$(yn "[ -f '$R/.harness/verify.sh' ]")"
  expect "skip ($c): only allowlisted read calls" 0 "$(offlist "$LOG")"
  expect "skip ($c): no gate card" no "$(yn "[ -e '$R/$GATE' ]")"
  expect "skip ($c): exactly one branch-protection line" 1 "$(bplines "$OUT")"
  expect "skip ($c): line starts with 跳过分支保护检查：" yes "$(yn 'printf "%s\n" "$OUT" | grep -q "^跳过分支保护检查："')"
  if [ "$c" = noadmin ]; then
    expect "skip (noadmin): a non-plan 403 is not called a plan limit" no "$(yn 'printf "%s" "$OUT" | grep -q "Pro/Team"')"
    expect "skip (noadmin): line names acme/widget (repo known)" yes "$(yn 'bpline "$OUT" | grep -qF "acme/widget"')"
    expect "skip (noadmin): Actions permissions still asked (repo reachable)" 1 "$(called "$LOG" "$WFGET")"
  else
    expect "skip ($c): Actions not asked (repo not reachable)" 0 "$(called "$LOG" "$WFGET")"
  fi
done
expect "gh missing: no fallback to gh on PATH" no "$(yn "[ -e '$T/path-gh.log' ]")"

# ---------------------------------------------------------------- 超时：10 秒，自己的提示，之后不再调 gh
R="$(newrepo hang)"; run hang "$R" --yes
expect "hang: init exits 0" 0 "$RC"
expect "hang: gives up within ~10s (took ${SECS}s)" yes "$(yn '[ "$SECS" -lt 20 ]')"
expect "hang: waited for the 10s timeout (took ${SECS}s)" yes "$(yn '[ "$SECS" -ge 9 ]')"
expect "hang: exactly one branch-protection line" 1 "$(bplines "$OUT")"
expect "hang: skip line says 超时" yes "$(yn 'printf "%s\n" "$OUT" | grep "^跳过分支保护检查：" | grep -q "超时"')"
expect "hang: line names acme/widget (repo view had answered)" yes "$(yn 'bpline "$OUT" | grep -qF "acme/widget"')"
expect "hang: no more gh calls after the timeout" 2 "$(wc -l < "$LOG" | tr -d ' ')"
expect "hang: no gate card" no "$(yn "[ -e '$R/$GATE' ]")"

# ---------------------------------------------------------------- dry-run：说会做什么，不写任何东西
R="$(newrepo dry)"; run public "$R" --dry-run
expect "dry-run: exits 0" 0 "$RC"
expect "dry-run: only allowlisted read calls" 0 "$(offlist "$LOG")"
expect "dry-run: did the read-only check" yes "$(yn "grep -qF 'branches/trunk/protection' '$LOG'")"
expect "dry-run: says it would open G-SETUP-bp" yes "$(yn 'printf "%s" "$OUT" | grep -q "G-SETUP-bp"')"
expect "dry-run: line names acme/widget" yes "$(yn 'bpline "$OUT" | grep -qF "acme/widget"')"
expect "dry-run: does not claim it opened a card" no "$(yn 'printf "%s" "$OUT" | grep -q "已开门卡"')"
expect "dry-run: no gate card" no "$(yn "[ -e '$R/$GATE' ]")"
expect "dry-run: nothing written at all" "" "$(cd "$R" && git status --porcelain --untracked-files=all | grep -v '^?? pyproject.toml$')"
R="$(newrepo dryfree)"; run free "$R" --dry-run
expect "dry-run free: explains Pro/Team, only allowlisted reads" "yes 0" "$(yn 'printf "%s" "$OUT" | grep -q "Pro/Team"') $(offlist "$LOG")"

# ---------------------------------------------------------------- 插件模式（/harness:setup）同样检查
R="$(newrepo plug)"; run public "$R" --plugin --yes
expect "plugin: init exits 0" 0 "$RC"
expect "plugin: only allowlisted read calls" 0 "$(offlist "$LOG")"
expect "plugin: gate card written" yes "$(yn "[ -f '$R/$GATE' ] && grep -qF -- '$PUT_BP' '$R/$GATE'")"
expect "plugin: exactly one branch-protection line" 1 "$(bplines "$OUT")"
expect "setup skill tells the user about branch protection" yes "$(yn "grep -q '分支保护' '$SRC/plugin/skills/setup/SKILL.md'")"
expect "real gh on PATH never used in any case" no "$(yn "[ -e '$T/path-gh.log' ]")"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
