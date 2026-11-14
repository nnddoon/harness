#!/usr/bin/env bash
# T-020 验收（S-003#5 #9，现场报告 F-8 F-11）：
#   L. lint：pkg/scripts/*.sh 与构建后的插件（payload 等）里的 bash 脚本
#      (a) 没有 `$NAME` 后紧跟非 ASCII 字节（macOS bash 3.2 + UTF-8 会把它读成变量名的一部分，set -u 下直接退出）
#      (b) 没有 bash 4 才有的写法：declare -A、local -A、${v,,} ${v^^} ${v,} ${v^}、mapfile、readarray、|&、&>>、coproc、;&、;;&
#      (c) /bin/bash 是 3.x 时：LC_ALL=en_US.UTF-8 /bin/bash -n 每个脚本 + 每个脚本跑一次不碰外部的冒烟；否则 SKIP
#   S. 调度：pick-batch 只返回 new-task.sh 会认领的任务（backlog 行 ready 且任务卡 status ready|claimed）；
#      backlog-status 不带参数退出 2 并打印用法。
# 按任务卡 T-020「接口约定」与「接口约定 v2」。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-bash32.XXXXXX")"; trap 'rm -rf "$T"' EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }

# lint <文件…>：每处违规一行「<文件>:<行>: <规则>: <片段>」。规则：nonascii | bash4 | array
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
    # v2（接口约定 v2）：bash 4.x / 5.x 才有的写法
    ("typeset -A", re.compile(rb'\btypeset\s+-[A-Za-z]*A')),
    ("declare -n/-g/-l/-u", re.compile(rb'\b(declare|typeset|local)\s+-[A-Za-z]*[nglu]')),
    ("[[ -v", re.compile(rb'(\[\[?\s+(!\s+)?|\btest\s+(!\s+)?)-v\s')),
    ("${v@op}", re.compile(rb'\$\{[#!]?[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?@[A-Za-z]\}')),
    ("${a[-1]}", re.compile(rb'\$\{[#!]?[A-Za-z_][A-Za-z0-9_]*\[\s*-')),
    ("wait -n", re.compile(rb'\bwait\s+(-[A-Za-z]+\s+)*-[A-Za-z]*n')),
    ("$EPOCHSECONDS", re.compile(rb'\$\{?EPOCH(SECONDS|REALTIME)\b')),
    ("$BASHPID", re.compile(rb'\$\{?BASHPID\b')),
    ("shopt globstar/lastpipe/…", re.compile(rb'\bshopt\b.*\b(globstar|lastpipe|autocd|checkjobs|dirspell|globasciiranges'
                                             rb'|direxpand|inherit_errexit|localvar_inherit|assoc_expand_once)\b')),
    ("{fd}> redirection", re.compile(rb'(?<![$\w])\{[A-Za-z_][A-Za-z0-9_]*\}(>>|<>|>&|<&|>|<)')),
    ("read -i/-N", re.compile(rb'\bread\b(\s+-[A-Za-z]+)*\s+-[A-Za-z]*[iN]')),
    ("{1..9..2}", re.compile(rb'\{[-+]?\w+\.\.[-+]?\w+\.\.[-+]?\d+\}')),
]
# (d) set -u 下 "${X[@]}" / ${X[*]} 必须有保护（bash < 4.4 对空数组报 unbound variable）：
#     ${X[@]+"${X[@]}"} / ${X[@]:+…} / ${X[@]:-…} / ${#X[@]} 都算有保护；ARRAY_ALLOW 里的名字（必定非空的字面量数组）除外
import os
ALLOW = set(os.environ.get("ARRAY_ALLOW", "").split())
SETU = re.compile(rb'^\s*set\s+(-[A-Za-z]*u|.*-o\s+nounset)', re.M)
GUARDED = re.compile(rb'\$\{([A-Za-z_][A-Za-z0-9_]*)\[([@*])\]:?\+"?\$\{\1\[\2\]\}"?\}')
BARE = re.compile(rb'\$\{([A-Za-z_][A-Za-z0-9_]*)\[[@*]\]\}')
for path in sys.argv[1:]:
    with open(path, "rb") as fh:
        data = fh.read()
    lines, setu = data.split(b"\n"), bool(SETU.search(data))
    for i, line in enumerate(lines, 1):
        m = NONASCII.search(line)
        if m:
            print(f"{path}:{i}: nonascii: {m.group().decode('utf-8', 'replace')}")
        if line.lstrip().startswith(b"#"):
            continue
        for name, rx in BASH4:
            if rx.search(line):
                print(f"{path}:{i}: bash4 {name}: {line.strip().decode('utf-8', 'replace')[:100]}")
        if setu:
            for m in BARE.finditer(GUARDED.sub(b"", line)):
                if m.group(1).decode() not in ALLOW:
                    print(f"{path}:{i}: array: {m.group().decode()} 在 set -u 下没有保护")
PY
# 允许不加保护的数组：在用到它的每个脚本里都赋过非空字面量、从不赋成空（下面有自检）
ARRAY_ALLOW="GIT MGIT CTL CTLLIB LAUNCH"
lint() { ARRAY_ALLOW="$ARRAY_ALLOW" python3 -B "$LINT" "$@"; }
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
# v2 自检：每条新规则都有一个必中样例
for c in 'typeset -A m' 'declare -n ref=x' 'declare -g G=1' 'declare -l low' 'declare -u up' '[[ -v FOO ]]' \
         'echo "${v@Q}"' 'echo "${a[@]@Q}"' 'echo "${v@U}"' 'echo "${a[-1]}"' 'wait -n' 'wait -f -n $p' \
         'echo "$EPOCHSECONDS"' 'echo ${EPOCHREALTIME}' 'echo $BASHPID' 'shopt -s globstar' 'shopt -s lastpipe' \
         'exec {fd}>log' 'exec {fd}<in' 'read -i x -e v' 'read -r -N 3 v' 'echo {1..9..2}'; do
  i=$((i+1)); printf '%s\n' "$c" > "$S/bad-b$i.sh"
  expect "lint self-check v2: bash4 flagged: $c" 1 "$(lint "$S/bad-b$i.sh" | grep -c ': bash4 ')"
done
printf '%s\n' 'declare -r R=1' 'declare -x X' 'local -i n' '[[ -n "$x" ]]' '[ -z "$x" ]' 'echo "${v:-@Q}" "$@" "${@}"' \
              'echo "${s: -1}" "${a[@]: -1}" "${a[1]}" "${#a[@]}"' 'wait "$pid"' 'echo "$SECONDS" $$' 'shopt -s nullglob' \
              'echo "${fd}">log' 'cmd 2>&1 >"$f"' 'read -r -p "x" v' 'read -rd "" v' 'echo {1..9} {a..z}' > "$S/ok-b2.sh"
expect "lint self-check v2: bash 3 forms not flagged" "" "$(lint "$S/ok-b2.sh")"
# (d) set -u 下的空数组
printf '%s\n' 'set -u' 'X=()' 'cmd "${X[@]}"' 'cmd ${Y[*]}' > "$S/bad-d.sh"
expect "lint self-check: unguarded \"\${X[@]}\" / \${Y[*]} under set -u flagged" 2 "$(lint "$S/bad-d.sh" | grep -c ': array:')"
printf '%s\n' 'set -euo pipefail' 'X=()' 'cmd ${X[@]+"${X[@]}"} ${X[*]:+"${X[*]}"} "${X[@]:-}" "${#X[@]}"' \
              'GIT=(git -c a=b)' '"${GIT[@]}" status' > "$S/ok-d.sh"
expect "lint self-check: guarded forms and allowlisted arrays pass" "" "$(lint "$S/ok-d.sh")"
printf '%s\n' 'X=()' 'cmd "${X[@]}"' > "$S/ok-d2.sh"
expect "lint self-check: no set -u → array rule off" "" "$(lint "$S/ok-d2.sh")"

# ---------------------------------------------------------------- L(a)(b)：pkg/scripts/*.sh
for f in "$SRC"/scripts/*.sh; do
  r="scripts/$(basename "$f")"
  expect "lint (a) no \$NAME+non-ASCII in pkg/$r" "" "$(lint "$f" | grep ': nonascii:' | sed "s#^$SRC/##")"
  expect "lint (b) no bash 4 constructs in pkg/$r" "" "$(lint "$f" | grep ': bash4 ' | sed "s#^$SRC/##")"
  expect "lint (d) no unguarded \${X[@]} under set -u in pkg/$r" "" "$(lint "$f" | grep ': array:' | sed "s#^$SRC/##")"
done
# 白名单自检：名单里的数组，在用到它的每个脚本里都赋过非空字面量、从没赋成 ()
allow_bad=""
for f in "$SRC"/scripts/*.sh; do
  for a in $ARRAY_ALLOW; do
    grep -q "\${$a\[[@*]\]}" "$f" || continue
    grep -Eq "(^|[[:space:];])$a=\([^)]" "$f" || allow_bad="$allow_bad $(basename "$f"):$a(没有非空赋值)"
    grep -Eq "(^|[[:space:];])$a=\(\)" "$f" && allow_bad="$allow_bad $(basename "$f"):$a(赋成空)"
  done
done
expect "array allowlist is justified (non-empty literal, never emptied)" "" "$allow_bad"

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
  expect "lint (d) no unguarded \${X[@]} under set -u in plugin/$r" "" "$(lint "$f" | grep ': array:' | sed "s#^$PLUG/##")"
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
  printf '#!/bin/sh\nexit 0\n' > "$FB/claude"
  # 假 crontab：-l 读 $CRONFILE（没有就 exit 1，同真 crontab），- 读完 stdin 再整表替换（同真 crontab，管道里先读后写）
  printf '%s\n' '#!/bin/sh' 'case "$1" in' \
    '  -l) [ -f "$CRONFILE" ] || { echo "no crontab for you" >&2; exit 1; }; cat "$CRONFILE";;' \
    '  -) cat > "$CRONFILE.new" && mv "$CRONFILE.new" "$CRONFILE";;' 'esac' > "$FB/crontab"
  # 假 gh（v2）：auth status 成功、repo view 给 acme/widget，其余回 []；只为让 gate-sync 走过「已登录」路径
  printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$FAKEGH_LOG"' 'case "$1 $2" in' \
    '  "auth status") echo "Logged in to github.com account me";;' \
    '  "repo view") echo "acme/widget";;' '  *) echo "[]";;' 'esac' > "$FB/gh"
  chmod +x "$FB"/*
  CRONFILE="$T/crontab.txt"; export CRONFILE
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
  # v2：假 gh 的 auth status 成功 → gate-sync 不该再报「未登录」
  expect "bash $BVER smoke ($U8): fake gh auth status succeeds" 0 "$(PATH="$FB:$PATH" FAKEGH_LOG="$T/gh.log" gh auth status >/dev/null 2>&1; echo $?)"
  expect "bash $BVER smoke ($U8): gate-sync gets past the gh login check" no \
    "$(grep -q 'gh 未登录或不是 GitHub 仓库' "$T/smoke.out" && echo yes || echo no)"
  expect "bash $BVER smoke ($U8): gate-sync sync has no traceback" no "$(grep -q Traceback "$T/smoke.out" && echo yes || echo no)"
  # v2：过期的定时任务 → check_expiry（含 HARNESS_NOW 不是数字那一行）在 UTF-8 下跑到底
  MAINR="$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
  printf '%s\n' '0 3 * * * other-job' \
    "*/5 * * * * cd \"$MAINR\" && scripts/gate-sync.sh --resume --quiet # harness repo=$MAINR expires=2000-01-01" > "$CRONFILE"
  HARNESS_NOW=bogus smoke "gate-sync.sh expired cron (check_expiry)" scripts/gate-sync.sh
  expect "bash $BVER smoke ($U8): check_expiry reports expiry" yes \
    "$(grep -qF '定时任务已到期（expires=2000-01-01）' "$T/smoke.out" && echo yes || echo no)"
  expect "bash $BVER smoke ($U8): check_expiry warns on non-numeric HARNESS_NOW" yes \
    "$(grep -qF 'HARNESS_NOW 不是数字（bogus）' "$T/smoke.out" && echo yes || echo no)"
  expect "bash $BVER smoke ($U8): expired harness cron line removed, other jobs kept" "0 1" \
    "$(grep -c '# harness repo=' "$CRONFILE") $(grep -c 'other-job' "$CRONFILE")"
  expect "bash $BVER smoke ($U8): expired-cron.txt written" yes \
    "$(grep -qF 'expires=2000-01-01' "$MAINR/.harness/reports/expired-cron.txt" 2>/dev/null && echo yes || echo no)"
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
    out=" $($L pick-batch "$n" --skip "$sk" 2>/dev/null) "
    case "$out" in *" T-031 "*|*" T-032 "*) hit="$hit n=$n skip=$sk:$out";; esac
  done
done
expect "pick-batch never returns a proposed task (card or backlog)" "" "$hit"
expect "pick-batch with only proposed left returns nothing" "" "$($L pick-batch 3 --skip T-030,T-034 2>/dev/null)"

# v2 (3)：waves 第 1 批 = 可认领的（claimable）；卡上不可认领的 ready 行和 proposed 一样，不进任何一批
expect "v2 waves: batch 1 only claimable tasks" "第 1 批: T-030 T-034" "$($L waves 2>/dev/null | head -n1)"
expect "v2 waves: card-proposed T-031 is in no batch" 0 "$($L waves 2>/dev/null | grep -c 'T-031')"
# v2 (4)：因任务卡状态被跳过的 ready 行 → stderr 每个一行「跳过 T-xxx：任务卡状态是 <s>」（与 N 无关；--skip 里的不报）
$L pick-batch 5 > "$T/pb.out" 2> "$T/pb.err"
expect "v2 pick-batch stdout unchanged by the notice" "T-030 T-034" "$(cat "$T/pb.out")"
expect "v2 pick-batch stderr names the skipped task and its card status" "跳过 T-031：任务卡状态是 proposed" "$(cat "$T/pb.err")"
expect "v2 pick-batch 1 still reports the skip" "跳过 T-031：任务卡状态是 proposed" "$($L pick-batch 1 2>&1 >/dev/null)"
expect "v2 pick-batch: ids in --skip are not reported" "" "$($L pick-batch 5 --skip T-031 2>&1 >/dev/null)"
# 夜间流程的晨报列出被跳过的任务（每个一次）：--integration 与 --until 两条出晨报的路径
FBL="$T/fbin-loop"; mkdir -p "$FBL"; printf '#!/bin/sh\nexit 0\n' > "$FBL/claude"; chmod +x "$FBL/claude"
for mode in "--integration" "--until +600"; do
  R3="$T/repo3-${mode%% *}"; R3="${R3//--/}"; cp -R "$R2" "$R3"
  (cd "$R3" && HARNESS_GATE_CHANNEL=off HARNESS_CLAUDE="$FBL/claude" XDG_STATE_HOME="$T/state3" \
     scripts/harness-loop.sh --dry-run $mode --max-tasks 5 --no-groom --no-replan > "$T/loop3.out" 2>&1)
  MR="$(ls "$R3"/.harness/reports/morning-*.md 2>/dev/null | head -n1)"
  expect "v2 loop $mode: morning report written" yes "$([ -n "$MR" ] && echo yes || echo no)"
  expect "v2 loop $mode: morning report lists the skipped T-031 once" 1 "$(grep -cF '跳过 T-031：任务卡状态是 proposed' "${MR:-/dev/null}")"
  expect "v2 loop $mode: morning report does not list dispatchable tasks as skipped" 0 "$(grep -cE '跳过 T-03[024]' "${MR:-/dev/null}")"
done
# 卡片转 ready 之后才派
sed -i.bak 's/^status: proposed /status: ready    /' .harness/tasks/T-031-x.md; rm -f .harness/tasks/T-031-x.md.bak
expect "pick-batch picks T-031 once its card is ready" "T-031" "$($L pick-batch 3 --skip T-030,T-034)"
expect "v2 waves: T-031 joins batch 1 once its card is ready" "第 1 批: T-030 T-031 T-034" "$($L waves 2>/dev/null | head -n1)"
expect "v2 pick-batch: no skip notice once the card is ready" "" "$($L pick-batch 5 2>&1 >/dev/null)"

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
