#!/usr/bin/env bash
# T-002 验收：harness serve 只读看板三屏。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-serve.XXXXXX")"
PID=""; trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$T"' EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }

# ---------------------------------------------------------------- fixture repo
R="$T/repo"; mkdir -p "$R" && cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
cp -R "$SRC/.claude" "$SRC/.harness" . && rm -rf .harness/reports .harness/STATUS.md
mkdir -p docs/specs .harness/reports
printf '# S-001 演示规格\n\n目标：一句话。\n' > docs/specs/S-001-demo.md
sed -e 's/T-000/T-001/g' -e 's/^status: proposed /status: review   /' -e 's/^title: .*/title: 演示任务/' -e 's/^spec: .*/spec: S-001/' \
    .harness/tasks/_TEMPLATE.md > .harness/tasks/T-001-demo.md
python3 - <<'PY'
p = ".harness/tasks/T-001-demo.md"; s = open(p, encoding="utf-8").read()
i, j = s.index("## 5."), s.index("## 6.")
s = s[:i] + "## 5. 验收标准\n- [x] A1 一\n- [x] A2 二\n- [ ] A3 三\n\n" + s[j:]
open(p, "w", encoding="utf-8").write(s)
b = ".harness/backlog.md"; s = open(b, encoding="utf-8").read()
s = s.replace("- T-001 | proposed | P1 | 示例：播放器倍速切换 | deps: - | auto_ok: no | owner: -",
              "- T-001 | review | P1 | 演示任务 | deps: - | auto_ok: no | owner: -")
open(b, "w", encoding="utf-8").write(s)
PY
gate() {  # gate <id> <urgency> <minutes> <status> <title>
  printf -- '---\nid: %s\ntask: T-001\nkind: sensory\nstatus: %s\nurgency: %s\nrecommended: A\nreview_minutes: %s\ndefault_if_no_answer: 按推荐继续\n---\n\n# %s %s\n\n## 选项\n- **A（推荐）**：变速不变调\n- **B**：直接加速\n' \
    "$1" "$4" "$2" "$3" "$1" "$5" > ".harness/gates/$1.md"
}
gate G-T001-1 normal 5 open "普通五分钟"
gate G-T001-2 high 10 open "紧急十分钟"
gate G-T001-3 normal 2 open "两分钟<script>alert(1)</script>"
gate G-T001-4 normal 3 answered "已答复不该出现"
printf '# 晨报\n\n状态：done 1\n先看这 3 个 diff：\n  - T-001：`git diff a^1 a`\n' > .harness/reports/morning-20261111.md
git add -A && git commit -qm fixture

# ---------------------------------------------------------------- start
python3 "$SRC/cli/serve_cmd.py" --repo "$R" --port 0 > "$T/serve.out" 2>&1 &
PID=$!
for _ in $(seq 1 50); do grep -q '^http://' "$T/serve.out" 2>/dev/null && break; sleep 0.1; done
URL="$(grep -m1 '^http://' "$T/serve.out")"
expect "listens on 127.0.0.1 only" yes "$(case "$URL" in http://127.0.0.1:*) echo yes;; *) echo no;; esac)"
get() { curl -s "$URL${1#/}"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

HOME_HTML="$(get /)"
expect "decide: 200" 200 "$(code "$URL")"
expect "decide: shows review load" yes "$(printf '%s' "$HOME_HTML" | grep -q '约 19 分钟（4 项）' && echo yes || echo no)"
pos() { printf '%s' "$HOME_HTML" | grep -o "$1" | head -1 >/dev/null && printf '%s' "$HOME_HTML" | awk -v k="$1" '{i=index($0,k); if(i){print NR*100000+i; exit}}'; }
P2=$(pos 紧急十分钟); P3=$(pos 两分钟); P1=$(pos 普通五分钟)
expect "decide: urgent first, then shorter first" yes "$([ -n "$P2" ] && [ -n "$P3" ] && [ -n "$P1" ] && [ "$P2" -lt "$P3" ] && [ "$P3" -lt "$P1" ] && echo yes || echo no)"
expect "decide: answered gates hidden" no "$(printf '%s' "$HOME_HTML" | grep -q '已答复不该出现' && echo yes || echo no)"
expect "decide: text from files is escaped" yes "$(printf '%s' "$HOME_HTML" | grep -q '&lt;script&gt;alert(1)&lt;/script&gt;' && echo yes || echo no)"
expect "decide: no raw script from files" no "$(printf '%s' "$HOME_HTML" | grep -q '<script>alert' && echo yes || echo no)"
expect "decide: shows options and the recommendation" yes "$(printf '%s' "$HOME_HTML" | grep -q '变速不变调' && printf '%s' "$HOME_HTML" | grep -q '推荐' && echo yes || echo no)"
expect "decide: says what happens if you don't answer" yes "$(printf '%s' "$HOME_HTML" | grep -q '按推荐继续' && echo yes || echo no)"

M="$(get /morning)"
expect "morning: shows the latest report" yes "$(printf '%s' "$M" | grep -q 'done 1' && echo yes || echo no)"
expect "morning: renders code" yes "$(printf '%s' "$M" | grep -q '<code>git diff a^1 a</code>' && echo yes || echo no)"
rm .harness/reports/morning-20261111.md
expect "morning: computed live when no report" yes "$(get /morning | grep -q '状态' && echo yes || echo no)"

NEEDS="$(get /needs)"
expect "needs: lists the spec" yes "$(printf '%s' "$NEEDS" | grep -q 'S-001 演示规格' && echo yes || echo no)"
expect "needs: task under its spec with acceptance count" yes "$(printf '%s' "$NEEDS" | grep -q 'T-001' && printf '%s' "$NEEDS" | grep -q '2/3' && echo yes || echo no)"

expect "DNS rebinding: foreign Host header rejected" 421 "$(code -H 'Host: evil.example' "$URL")"
PORT="$(printf '%s' "$URL" | sed 's#.*:\([0-9]*\)/$#\1#')"
expect "localhost Host header accepted" 200 "$(code -H "Host: localhost:$PORT" "$URL")"
expect "POST refused" 405 "$(code -X POST "$URL")"
expect "unknown path" 404 "$(code "${URL}nope")"
expect "no path traversal" 404 "$(code --path-as-is "${URL}../../etc/passwd")"
expect "stdlib only" "" "$(grep -E '^(import|from) ' "$SRC/cli/serve_cmd.py" | grep -vE '^(import|from) (html|hmac|http|json|os|re|secrets|sys|glob|datetime|importlib|pathlib|socketserver|subprocess|urllib|functools|typing)\b' )"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
