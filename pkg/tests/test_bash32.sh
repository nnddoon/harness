#!/usr/bin/env bash
# T-020 验收（S-003#5 #9，现场报告 F-8 F-11）：
#   L. lint：pkg/scripts/*.sh 与构建后的插件（payload 等）里的 bash 脚本
#      (a) 没有 `$NAME` 后紧跟非 ASCII 字节（macOS bash 3.2 + UTF-8 会把它读成变量名的一部分，set -u 下直接退出）
#      (b) 没有 bash 4 才有的写法：declare -A、local -A、${v,,} ${v^^} ${v,} ${v^}、mapfile、readarray、|&、&>>、coproc、;&、;;&
#      (c) /bin/bash 是 3.x 时：LC_ALL=en_US.UTF-8 /bin/bash -n 每个脚本 + 每个脚本跑一次不碰外部的冒烟；否则 SKIP
#   S. 调度：pick-batch 只返回 new-task.sh 会认领的任务（backlog 行 ready 且任务卡 status ready|claimed）；
#      backlog-status 不带参数退出 2 并打印用法。
# 按任务卡 T-020「接口约定」。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-bash32.XXXXXX")"; trap 'rm -rf "$T"' EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }

# lint <文件…>：每处违规一行「<文件>:<行>: <规则>: <片段>」。规则：nonascii | bash4
LINT="$T/lint.py"
cat > "$LINT" <<'PY'
import re, sys
# (a) $NAME 后紧跟非 ASCII 字节（按字节匹配，与 locale 无关）。${NAME} 不算。
NONASCII = re.compile(rb'\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xff]')
# (b) bash 4 写法；整行注释不查（注释里写「别用 mapfile」不算违规）
BASH4 = [
    ("declare -A", re.compile(rb'\bdeclare\s+-[A-Za-z]*A')),
    ("local -A", re.compile(rb'\blocal\s+-[A-Za-z]*A')),
    ("${var,,}/${var^^}", re.compile(rb'\$\{[#!]?[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,?|\^\^?)[^}]*\}')),
    ("mapfile", re.compile(rb'(^|[\s;&|(`])mapfile\b')),
    ("readarray", re.compile(rb'(^|[\s;&|(`])readarray\b')),
    ("|&", re.compile(rb'(?<!\|)\|&')),
    ("&>>", re.compile(rb'&>>')),
    ("coproc", re.compile(rb'(^|[\s;&|(`])coproc\b')),
    (";;&", re.compile(rb';;&')),
    (";&", re.compile(rb'(?<!;);&')),
]
for path in sys.argv[1:]:
    with open(path, "rb") as fh:
        lines = fh.read().split(b"\n")
    for i, line in enumerate(lines, 1):
        m = NONASCII.search(line)
        if m:
            print(f"{path}:{i}: nonascii: {m.group().decode('utf-8', 'replace')}")
        if line.lstrip().startswith(b"#"):
            continue
        for name, rx in BASH4:
            if rx.search(line):
                print(f"{path}:{i}: bash4 {name}: {line.strip().decode('utf-8', 'replace')[:100]}")
PY
lint() { python3 -B "$LINT" "$@"; }
rel() { printf '%s' "${1#"$2"/}"; }

# ---------------------------------------------------------------- lint 自检（正 / 反对照：规则本身靠得住）
S="$T/sample"; mkdir -p "$S"
printf 'echo "$TID（x）"\n' > "$S/bad-a.sh"
printf 'echo "${TID}（x）" "$TID" "$1（" "$TID x"\n' > "$S/ok-a.sh"
expect "lint self-check: \$NAME + 全角 is flagged" 1 "$(lint "$S/bad-a.sh" | grep -c ': nonascii:')"
expect "lint self-check: \${NAME} / \$1 / ASCII after \$NAME pass" "" "$(lint "$S/ok-a.sh")"
i=0
for c in 'declare -A m' 'local -A m' 'echo "${v,,}"' 'echo "${v^^}"' 'mapfile -t a < f' 'readarray a < f' \
         'cmd |& tee x' 'cmd &>> log' 'coproc cat' '  a) echo;&' '  a) echo;;&'; do
  i=$((i+1)); printf '%s\n' "$c" > "$S/bad-b$i.sh"
  expect "lint self-check: bash4 flagged: $c" 1 "$(lint "$S/bad-b$i.sh" | grep -c ': bash4 ')"
done
printf '%s\n' 'declare -a arr' 'local -a xs' 'echo "${v}" "${v:-x}" "${#v}" "${v//a/b}"' '  a) echo;;' \
              'a || b' 'cmd >> log 2>&1' 'x && y' '# mapfile 是 bash 4 的，别用' > "$S/ok-b.sh"
expect "lint self-check: bash 3 forms not flagged" "" "$(lint "$S/ok-b.sh")"

# ---------------------------------------------------------------- L(a)(b)：pkg/scripts/*.sh
for f in "$SRC"/scripts/*.sh; do
  r="scripts/$(basename "$f")"
  expect "lint (a) no \$NAME+non-ASCII in pkg/$r" "" "$(lint "$f" | grep ': nonascii:' | sed "s#^$SRC/##")"
  expect "lint (b) no bash 4 constructs in pkg/$r" "" "$(lint "$f" | grep ': bash4 ' | sed "s#^$SRC/##")"
done

# ---------------------------------------------------------------- L(a)(b)：构建后的插件里的 bash 脚本
PLUG="$T/plugin"
bash "$SRC/plugin/build.sh" "$PLUG" > "$T/build.out" 2>&1
expect "plugin builds into a temp dir" 0 "$?"
PAYSH="$T/payload-scripts.txt"
python3 -B - "$PLUG" > "$PAYSH" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
for f in sorted(root.rglob("*")):
    if not f.is_file():
        continue
    head = f.open("rb").readline()
    if f.suffix == ".sh" or (head.startswith(b"#!") and b"bash" in head):
        print(f)
PY
expect "built plugin has payload scripts to lint" yes "$(grep -q '/payload/scripts/harness-loop.sh$' "$PAYSH" && echo yes || echo no)"
while IFS= read -r f; do
  r="$(rel "$f" "$PLUG")"
  expect "lint (a) no \$NAME+non-ASCII in plugin/$r" "" "$(lint "$f" | grep ': nonascii:' | sed "s#^$PLUG/##")"
  expect "lint (b) no bash 4 constructs in plugin/$r" "" "$(lint "$f" | grep ': bash4 ' | sed "s#^$PLUG/##")"
done < "$PAYSH"

# ---------------------------------------------------------------- L(c)：真 bash 3.x（macOS /bin/bash）下 -n + 冒烟
B32="${HARNESS_TEST_BASH32:-/bin/bash}"   # 调试用：指向别的 bash；HARNESS_TEST_BASH32_FORCE=1 时非 3.x 也跑
BVER="$("$B32" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo none)"
if [ "$BVER" = 3 ] || [ "${HARNESS_TEST_BASH32_FORCE:-}" = 1 ]; then
  U8="${HARNESS_TEST_UTF8_LOCALE:-en_US.UTF-8}"
  bad_bash() { grep -E 'unbound variable|bad substitution|syntax error|invalid option|not found: (declare|mapfile)' "$1" | head -3; }
  for f in "$SRC"/scripts/*.sh $(cat "$PAYSH"); do
    LC_ALL="$U8" "$B32" -n "$f" > "$T/n.out" 2>&1
    expect "bash $BVER -n ($U8): ${f#"$T"/}" "0" "$?$(bad_bash "$T/n.out")"
  done
  # 冒烟：一次性仓库，只用假 claude / gh / crontab，dry-run 或只读路径；看 bash 层面有没有报错
  R="$T/repo"; mkdir -p "$R" && cd "$R" || exit 1
  git init -q -b main && git config user.email t@t && git config user.name t
  cp -R "$SRC/CLAUDE.md" "$SRC/.claude" "$SRC/.harness" "$SRC/scripts" .
  rm -rf .claude/worktrees .harness/logs; printf '.claude/worktrees/\n.harness/logs/\n__pycache__/\n' > .gitignore
  sed -e 's/T-000/T-001/g' -e 's/^status: proposed /status: ready    /' -e 's#^allowed_paths: \[\]#allowed_paths: [src/**]#' \
      -e 's#^branch: .*#branch: task/T-001-demo#' .harness/tasks/_TEMPLATE.md > .harness/tasks/T-001-demo.md
  sed -i.bak 's/^- T-001 | proposed |/- T-001 | ready |/' .harness/backlog.md; rm -f .harness/backlog.md.bak
  git add -A && git commit -qm init
  FB="$T/fbin"; mkdir -p "$FB"
  printf '#!/bin/sh\nexit 0\n' > "$FB/claude"; printf '#!/bin/sh\nexit 0\n' > "$FB/crontab"
  cp "$SRC/tests/fake/gh" "$FB/gh"; chmod +x "$FB"/*
  smoke() {  # smoke <名称> <脚本> <参数…>
    local name="$1"; shift
    PATH="$FB:$PATH" FAKEGH_LOG="$T/gh.log" HARNESS_CLAUDE="$FB/claude" HARNESS_CRONTAB="$FB/crontab" \
      HARNESS_GATE_CHANNEL=off XDG_STATE_HOME="$T/state" LC_ALL="$U8" "$B32" "$@" > "$T/smoke.out" 2>&1 < /dev/null; [ -z "${HARNESS_TEST_SMOKE_SHOW:-}" ] || sed "s/^/    | /" "$T/smoke.out" | head -6
    expect "bash $BVER smoke ($U8): $name" "" "$(bad_bash "$T/smoke.out")"
  }
  smoke "harness-loop.sh --dry-run" scripts/harness-loop.sh --dry-run --max-tasks 1 --no-groom --no-replan
  smoke "harness-loop.sh --dry-run --integration" scripts/harness-loop.sh --dry-run --integration --max-tasks 1 --no-groom --no-replan
  smoke "gates.sh --all" scripts/gates.sh --all
  smoke "gate-sync.sh (sync once, fake gh)" scripts/gate-sync.sh
  smoke "new-task.sh --print-only" scripts/new-task.sh T-001 --print-only
  smoke "new-task.sh (no args → usage)" scripts/new-task.sh
  cd "$SRC" || exit 1
else
  echo "SKIP bash 3.2 实跑：$B32 是 bash ${BVER}（不是 3.x）；在 macOS 系统 bash 上会跑 -n 与冒烟"
fi

# ---------------------------------------------------------------- S：调度只派 ready；backlog-status 用法
R2="$T/repo2"; mkdir -p "$R2" && cd "$R2" || exit 1
git init -q -b main && git config user.email t@t && git config user.name t
cp -R "$SRC/CLAUDE.md" "$SRC/.claude" "$SRC/.harness" "$SRC/scripts" .
rm -rf .claude/worktrees .harness/logs; printf '.claude/worktrees/\n.harness/logs/\n__pycache__/\n' > .gitignore
sed -i.bak '/^- T-001 /d' .harness/backlog.md; rm -f .harness/backlog.md.bak
mkcard() {  # mkcard <id> <卡上 status> <backlog status> <paths>
  sed -e "s/T-000/$1/g" -e "s/^status: proposed /status: $2 /" -e "s#^allowed_paths: \[\]#allowed_paths: [$4]#" \
      -e "s#^branch: .*#branch: task/$1-x#" .harness/tasks/_TEMPLATE.md > ".harness/tasks/$1-x.md"
  echo "- $1 | $3 | P1 | $1 demo | deps: - | auto_ok: yes | owner: -" >> .harness/backlog.md
}
mkcard T-030 ready    ready    "src/a/**"   # 正常
mkcard T-031 proposed ready    "src/b/**"   # F-11：groom 把 backlog 行转 ready，卡上仍是 proposed
mkcard T-032 ready    proposed "src/c/**"   # backlog 行 proposed
mkcard T-034 claimed  ready    "src/d/**"   # 整合失败重开：backlog 回 ready、主仓库卡仍是 claimed（new-task.sh 接受）
git add -A && git commit -qm init
L="python3 -B .claude/hooks/harness_lib.py"
expect "card status of the F-11 fixture is proposed" proposed "$($L card-status T-031 2>/dev/null | tr -d '[:space:]')"
expect "pick-batch 5: only tasks new-task.sh would claim" "T-030 T-034" "$($L pick-batch 5)"
hit=""
for n in 1 2 3 4 5; do
  for sk in none T-030 T-030,T-034 T-034; do
    out=" $($L pick-batch "$n" --skip "$sk") "
    case "$out" in *" T-031 "*|*" T-032 "*) hit="$hit n=$n skip=$sk:$out";; esac
  done
done
expect "pick-batch never returns a proposed task (card or backlog)" "" "$hit"
expect "pick-batch with only proposed left returns nothing" "" "$($L pick-batch 3 --skip T-030,T-034)"
# 卡片转 ready 之后才派
sed -i.bak 's/^status: proposed /status: ready    /' .harness/tasks/T-031-x.md; rm -f .harness/tasks/T-031-x.md.bak
expect "pick-batch picks T-031 once its card is ready" "T-031" "$($L pick-batch 3 --skip T-030,T-034)"

$L backlog-status > "$T/bs.out" 2> "$T/bs.err"; rc=$?
expect "backlog-status with no args exits 2" 2 "$rc"
expect "backlog-status with no args prints usage on stderr" yes \
  "$(grep -q '用法' "$T/bs.err" && grep -q 'backlog-status T-xxx' "$T/bs.err" && echo yes || echo no)"
expect "backlog-status with no args: no traceback" no "$(grep -q Traceback "$T/bs.err" && echo yes || echo no)"
expect "backlog-status with no args: nothing on stdout" "" "$(cat "$T/bs.out")"
expect "backlog-status T-030 still prints the status" ready "$($L backlog-status T-030)"
expect "backlog-status unknown id: empty, exit 0" ":0" "$($L backlog-status T-999):$?"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
