#!/usr/bin/env bash
# T-004 验收：需求页按 spec 的每条验收显示状态与证据，点开看影响范围、尝试日志、对抗审查。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-needs.XXXXXX")"
PID=""; trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$T"' EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
has() { printf '%s' "$PAGE" | grep -qF -- "$1" && echo yes || echo no; }

R="$T/repo"; mkdir -p "$R" && cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t
cp -R "$SRC/.claude" "$SRC/.harness" . && rm -f .harness/gates/G-*.md && mkdir -p docs/specs
cat > docs/specs/S-002-speed.md <<'MD'
# S-002 倍速与朗读

## 1. 目标
一句话。

## 6. 验收
1. 切换倍速不中断播放
2. 刷新后记住上次倍速
3. 2 倍速时人声自然
4. 不影响直播推流<b>粗</b>
MD
card() {  # card <tid> <status> <acceptance-lines> [attempt-rows] [adversarial-rows]
  sed -e "s/T-000/$1/g" -e "s/^status: proposed /status: $2/" -e 's/^spec: .*/spec: S-002/' \
      -e 's#^allowed_paths: \[\]#allowed_paths: [src/player/**]#' .harness/tasks/_TEMPLATE.md > ".harness/tasks/$1-x.md"
  python3 - ".harness/tasks/$1-x.md" "$3" "${4:-}" "${5:-}" <<'PY'
import sys
p, acc, att, adv = sys.argv[1:5]
s = open(p, encoding="utf-8").read()
def put(sec, body):
    global s
    i = s.index(f"## {sec}"); j = s.index("\n## ", i + 3) if "\n## " in s[i + 3:] else len(s)
    head = s[i:s.index("\n", i) + 1]
    s = s[:i] + head + body + "\n\n" + s[j + 1:] if j < len(s) else s[:i] + head + body + "\n"
put("5.", acc)
if att: put("11.", "| # | 假设 | 改动 | 结果 |\n|---|---|---|---|\n" + att)
if adv: put("13.", "| 轮 | 挑错数 | 成立 | 已处理 | 说明 |\n|---|---|---|---|---|\n" + adv)
open(p, "w", encoding="utf-8").write(s)
PY
}
card T-010 done "- [x] A1 切换不中断（S-002#1） — 证据：3 个测试全过"
card T-011 review "- [x] A1 刷新后保留（S-002#2） — 证据：4/4 通过" "| 1 | 存成文字 | x | 失败 |
| 2 | 转回数字 | y | 通过 |" "| 1 | 3 | 1 | 1 | 1 条成立已修 |"
card T-012 waiting_human "- [ ] B1 试听两段（S-002#3）"
python3 - <<'PY'
b = ".harness/backlog.md"; s = open(b, encoding="utf-8").read()
s = s.replace("- T-001 | proposed | P1 | 示例：播放器倍速切换 | deps: - | auto_ok: no | owner: -",
  "- T-010 | done | P1 | 切换 | deps: - | auto_ok: no | owner: -\n- T-011 | review | P1 | 记住 | deps: - | auto_ok: no | owner: -\n- T-012 | waiting_human | P1 | 试听 | deps: - | auto_ok: no | owner: -")
open(b, "w", encoding="utf-8").write(s)
PY
git add -A && git commit -qm fixture

python3 "$SRC/cli/serve_cmd.py" --repo "$R" --port 0 --read-only > "$T/s.out" 2>&1 &
PID=$!
for _ in $(seq 1 50); do grep -q '^http://' "$T/s.out" 2>/dev/null && break; sleep 0.1; done
U="$(grep -m1 '^http://' "$T/s.out" | sed 's#/$##')"
PAGE="$(curl -s "$U/needs")"
row() {  # row <n> -> the HTML of requirement S-002#n
  printf '%s' "$PAGE" | tr '\n' ' ' | grep -o "<li class=\"req\" id=\"S-002-$1\">.*" | sed 's#</li>.*##'
}
expect "summary counts per requirement" yes "$(has '4 句需求 · 1 做好了 · 1 等你看 · 1 等你 · 1 还没有任务')"
expect "#1 done with its evidence" yes "$(row 1 | grep -q '做好了' && row 1 | grep -q '3 个测试全过' && echo yes || echo no)"
expect "#2 waiting for your review" yes "$(row 2 | grep -q '等你看' && row 2 | grep -q '4/4 通过' && echo yes || echo no)"
expect "#3 waiting for you" yes "$(row 3 | grep -q '等你' && row 3 | grep -q 'T-012' && echo yes || echo no)"
expect "#4 has no task yet" yes "$(row 4 | grep -q '还没有任务' && echo yes || echo no)"
expect "requirement text is escaped" yes "$(row 4 | grep -qF '&lt;b&gt;粗&lt;/b&gt;' && echo yes || echo no)"
expect "details: impact (allowed paths)" yes "$(row 2 | grep -q 'src/player/\*\*' && echo yes || echo no)"
expect "details: attempts" yes "$(row 2 | grep -q '试了 2 次' && echo yes || echo no)"
expect "details: adversarial review" yes "$(row 2 | grep -q '1 条成立已修' && echo yes || echo no)"
expect "details open without JavaScript" yes "$(row 2 | grep -q '<details' && echo yes || echo no)"
expect "task table still there" yes "$(has 'T-011')"
expect "spec skill tells you to number acceptance" yes "$(grep -q 'S-xxx#' "$SRC/.claude/skills/spec/SKILL.md" && echo yes || echo no)"
expect "task template shows how to reference a requirement" yes "$(grep -q 'S-xxx#' "$SRC/.harness/tasks/_TEMPLATE.md" && echo yes || echo no)"

HOME_PAGE="$(curl -s "$U/")"
expect "decide page tells the truth when nothing is running" yes "$(printf '%s' "$HOME_PAGE" | grep -q '现在没有任务在跑' && echo yes || echo no)"
expect "decide page no longer claims everything is running" no "$(printf '%s' "$HOME_PAGE" | grep -q '其余的都在跑' && echo yes || echo no)"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
