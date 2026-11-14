#!/usr/bin/env bash
# T-018 验收：strict 加固——macOS 钥匙串（F-2）、验证入口文件（F-3）、claude.ai 连接器（F-4）、locked_paths 硬边界（F-10）。
# 按任务卡 T-018「接口约定」。外部命令全用假的：security（pkg/tests/fake/security，HARNESS_SECURITY）、
# claude（HARNESS_CLAUDE，记录 argv / 环境）、crontab（HARNESS_CRONTAB）。HARNESS_PLATFORM 覆盖平台检测。
# 调度器接入（harness-loop 带 --task 查 control-diff、钥匙串拒绝启动）在 pkg/scripts/test-harness.sh「strict hardening (T-018)」。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$SRC/.claude/hooks/harness_lib.py"
HOOKS="$SRC/.claude/hooks"
FAKESEC="$SRC/tests/fake/security"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-t018.XXXXXX")"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
has() { grep -qF -- "$2" "$1" 2>/dev/null && echo yes || echo no; }
PY3="$(command -v python3)"

# ---------------------------------------------------------------- 工具目录：常用命令 + 假 bwrap/socat/srt（linux strict 需要）
RB="$T/rbin"; FB="$T/fbin"; mkdir -p "$RB" "$FB"
for c in bash sh env cat mkdir sha1sum dirname basename uname id stat readlink realpath chmod ls grep sed awk \
         tr head tail cut printf test true false rm cp mv touch date sort uniq wc xargs find python3 git; do
  p="$(command -v "$c" 2>/dev/null)"; case "$p" in /*) ln -sf "$p" "$RB/$c";; esac
done
for c in bwrap socat srt; do printf '#!/bin/sh\nexit 0\n' > "$FB/$c"; chmod +x "$FB/$c"; done
DEPS="$FB:$RB"; NODEPS="$RB"
# 「security」放在 PATH 上的陷阱：HARNESS_SECURITY 必须被用到，不能落到 PATH 上的 security
TRAPB="$T/trapbin"; mkdir -p "$TRAPB"
printf '#!/bin/sh\necho "$*" >> "%s/path-security-called"\nexit 0\n' "$T" > "$TRAPB/security"; chmod +x "$TRAPB/security"

OUT="$T/out"; FAKE="$T/fake-claude"; ENVBIN="$(command -v env)"
cat > "$FAKE" <<SH
#!/bin/sh
: > "$OUT/ran"
for a in "\$@"; do printf '%s\n' "\$a"; done > "$OUT/argv"
"$ENVBIN" > "$OUT/env"
exit 0
SH
chmod +x "$FAKE"

HOMED="$T/home"; XDG="$T/state"; mkdir -p "$HOMED" "$XDG"
SECLOG="$T/seclog"
ENVX=()
# run PATH PLATFORM <harness_lib args...>   结果：$OUT/{rc,stdout,stderr,ran,argv,env}；security 调用记在 $SECLOG
run() {
  local path="$1" plat="$2"; shift 2
  rm -rf "$OUT"; mkdir -p "$OUT"; : > "$SECLOG"
  env -i HOME="$HOMED" XDG_STATE_HOME="$XDG" PATH="$path" HARNESS_PLATFORM="$plat" HARNESS_CLAUDE="$FAKE" \
      FAKE_SECURITY_LOG="$SECLOG" ${ENVX[@]+"${ENVX[@]}"} "$PY3" "$LIB" "$@" > "$OUT/stdout" 2> "$OUT/stderr"
  echo $? > "$OUT/rc"
}
rc() { cat "$OUT/rc"; }
ran() { [ -e "$OUT/ran" ] && echo yes || echo no; }
settings_path() { awk 'p{print; exit} $0=="--settings"{p=1}' "$OUT/argv" 2>/dev/null; }
grab() { local sp; sp="$(settings_path)"; if [ -n "$sp" ] && [ -f "$sp" ]; then cp "$sp" "$T/s-$1.json"; else echo '<<missing>>' > "$T/s-$1.json"; fi; }
argvline() { paste -sd'|' "$OUT/argv" 2>/dev/null; }
seccalls() { [ -s "$SECLOG" ] && wc -l < "$SECLOG" | tr -d ' ' || echo 0; }
# v2：只有 github.com 时的完整查询集合（每主机 3 条 + Claude Code 一条），排序后用 | 连接
secset() { LC_ALL=C sort "$SECLOG" 2>/dev/null | paste -sd'|' -; }
GHSET="$(printf '%s\n' 'find-generic-password -s gh:github.com' 'find-internet-password -s github.com' \
  'find-generic-password -s git:https://github.com' 'find-generic-password -s Claude Code-credentials' | LC_ALL=C sort | paste -sd'|' -)"

# q FILE EXPR —— 在配置 JSON 上求值 python 表达式，True→yes / False→no
cat > "$T/q.py" <<'PY'
import json, os, sys
try:
    s = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    s = None
def g(path, d=None):
    cur = s
    for k in path.split("."):
        if not isinstance(cur, dict) or k not in cur:
            return d
        cur = cur[k]
    return cur
def L(path):
    v = g(path, [])
    return v if isinstance(v, list) else []
R = os.environ.get("R", "")
def ab(root, p):
    return "/" + root + "/" + p
DW = lambda: L("sandbox.filesystem.denyWrite")
PD = lambda: L("permissions.deny")
def in_dw(p, root=None):
    root = root or R
    return ab(root, p) in DW() or ab(root, p) + "/**" in DW()
def ew(p, root=None):  # Edit 与 Write 两条 deny 都在
    root = root or R
    return ("Edit(%s)" % ab(root, p)) in PD() and ("Write(%s)" % ab(root, p)) in PD()
def no_ew(p, root=None):
    root = root or R
    return s is not None and ("Edit(%s)" % ab(root, p)) not in PD() and ("Write(%s)" % ab(root, p)) not in PD()
try:
    v = eval(sys.argv[2])
except Exception as e:
    v = "ERR:" + type(e).__name__
print("yes" if v is True else "no" if v is False else v)
PY
q() { R="${R:-}" "$PY3" "$T/q.py" "$1" "$2"; }

mkrepo() { mkdir -p "$T/$1" && git -C "$T/$1" init -q -b main && git -C "$T/$1" config user.email t@t && git -C "$T/$1" config user.name t; }
commitall() { git -C "$T/$1" add -A && git -C "$T/$1" commit -q -m "${2:-init}" --allow-empty; }
verify() { mkdir -p "$T/$1/.harness"; printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/$1/.harness/verify.sh"; }
quick() { mkdir -p "$T/$1/.harness"; printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/$1/.harness/quick-check.sh"; }

mkrepo kc; printf '{"name":"demo"}\n' > "$T/kc/package.json"; verify kc 'exit 0'; commitall kc

# ================================================================ A1：钥匙串（macOS）
R="$T/kc"
SEC=(HARNESS_SECURITY="$FAKESEC")
# gh:github.com 在钥匙串里 → strict 拒绝
ENVX=("${SEC[@]}" FAKE_SECURITY_GH=0)
run "$TRAPB:$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 keychain gh: strict exits 3" 3 "$(rc)"
expect "A1 keychain gh: claude not run" no "$(ran)"
expect "A1 keychain gh: fix mentions gh auth login --insecure-storage" yes "$(has "$OUT/stderr" 'gh auth login --insecure-storage')"
expect "A1 keychain gh: names the item gh:github.com" yes "$(has "$OUT/stderr" 'gh:github.com')"
expect "A1 keychain gh: mentions HARNESS_ALLOW_KEYCHAIN=1" yes "$(has "$OUT/stderr" 'HARNESS_ALLOW_KEYCHAIN=1')"
expect "A1 keychain gh: refusal uses the strict prefix" yes "$(has "$OUT/stderr" 'strict 模式无法启动 Claude')"
expect "A1 checks generic password exactly: find-generic-password -s gh:github.com" 1 "$(grep -cx 'find-generic-password -s gh:github.com' "$SECLOG" 2>/dev/null)"
expect "A1 checks internet password exactly: find-internet-password -s github.com" 1 "$(grep -cx 'find-internet-password -s github.com' "$SECLOG" 2>/dev/null)"
expect "A1 security never called with -w" 0 "$(grep -cE '(^| )-w( |$)' "$SECLOG" 2>/dev/null)"
expect "A1 security never called with -g" 0 "$(grep -cE '(^| )-g( |$)' "$SECLOG" 2>/dev/null)"
# v2（§9）：查询集合恰好是 github.com 的三项 + Claude Code 一项
expect "A1 v2 security queries are exactly the github.com set + Claude Code" "$GHSET" "$(secset)"
expect "A1 security output not echoed (no attributes in stdout/stderr)" 0 "$(cat "$OUT/stdout" "$OUT/stderr" | grep -c 'FAKE-KEYCHAIN-ATTR')"
expect "A1 no secret anywhere in launcher output" 0 "$(cat "$OUT/stdout" "$OUT/stderr" | grep -c 'FAKE-SECRET')"
expect "A1 HARNESS_SECURITY used, not the security on PATH" no "$([ -e "$T/path-security-called" ] && echo yes || echo no)"

# github.com 互联网密码（git osxkeychain）→ 拒绝，提示去掉 credential.helper
ENVX=("${SEC[@]}" FAKE_SECURITY_NET=0)
run "$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 keychain internet: strict exits 3" 3 "$(rc)"
expect "A1 keychain internet: claude not run" no "$(ran)"
expect "A1 keychain internet: fix mentions git config --global --unset credential.helper" yes "$(has "$OUT/stderr" 'git config --global --unset credential.helper')"
expect "A1 keychain internet: mentions osxkeychain" yes "$(has "$OUT/stderr" 'osxkeychain')"
expect "A1 keychain internet: names github.com" yes "$(has "$OUT/stderr" 'github.com')"

# 都有 → 两种修复都提
ENVX=("${SEC[@]}" FAKE_SECURITY_GH=0 FAKE_SECURITY_NET=0)
run "$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 keychain both: exits 3" 3 "$(rc)"
expect "A1 keychain both: both fixes named" "yes yes" "$(has "$OUT/stderr" '--insecure-storage') $(has "$OUT/stderr" 'credential.helper')"

# 钥匙串干净 → 正常启动
ENVX=("${SEC[@]}")
run "$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 clean keychain: strict exits 0" 0 "$(rc)"
expect "A1 clean keychain: claude ran with --settings" "--settings" "$(head -1 "$OUT/argv" 2>/dev/null)"
expect "A1 v2 clean keychain: every item was checked" "$GHSET" "$(secset)"

# HARNESS_ALLOW_KEYCHAIN=1 → 放行并警告
ENVX=("${SEC[@]}" FAKE_SECURITY_GH=0 HARNESS_ALLOW_KEYCHAIN=1)
run "$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 allow: strict exits 0" 0 "$(rc)"
expect "A1 allow: claude ran" yes "$(ran)"
expect "A1 allow: warning names HARNESS_ALLOW_KEYCHAIN=1" yes "$(has "$OUT/stderr" 'HARNESS_ALLOW_KEYCHAIN=1')"
expect "A1 allow: warning names the item" yes "$(has "$OUT/stderr" 'gh:github.com')"
expect "A1 allow: still no -w / -g" 0 "$(grep -cE '(^| )-(w|g)( |$)' "$SECLOG" 2>/dev/null)"
ENVX=("${SEC[@]}" FAKE_SECURITY_GH=0 HARNESS_ALLOW_KEYCHAIN=yes)
run "$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 allow must be literally 1: =yes still refused (3)" 3 "$(rc)"
expect "A1 allow=yes: claude not run" no "$(ran)"

# HARNESS_UNATTENDED=1（无 --strict）也算 strict
ENVX=("${SEC[@]}" FAKE_SECURITY_GH=0 HARNESS_UNATTENDED=1)
run "$NODEPS" macos launch --root "$R" -- -p hello
expect "A1 unattended implies strict: refused (3)" 3 "$(rc)"
expect "A1 unattended: claude not run" no "$(ran)"

# 只在 macOS 查；standard / --print-settings 不查
ENVX=("${SEC[@]}" FAKE_SECURITY_GH=0)
run "$DEPS" linux launch --strict --root "$R" -- -p hello
expect "A1 linux: keychain not consulted, strict runs" 0 "$(rc)"
expect "A1 linux: security never called" 0 "$(seccalls)"
run "$NODEPS" macos launch --root "$R" -- -p hello
expect "A1 standard on macos: runs" 0 "$(rc)"
expect "A1 standard on macos: security never called" 0 "$(seccalls)"
run "$NODEPS" macos launch --strict --print-settings --root "$R" -- -p hello
expect "A1 --print-settings on macos: exit 0" 0 "$(rc)"
expect "A1 --print-settings: security never called" 0 "$(seccalls)"

# security 不存在 → 视为没有凭证
ENVX=(HARNESS_SECURITY="$T/no-such-security")
run "$NODEPS" macos launch --strict --root "$R" -- -p hello
# v2（§9，失败即拒绝）：security 找不到 → 拒绝
expect "A1 v2 missing security binary: strict refused (3)" 3 "$(rc)"
expect "A1 v2 missing security binary: claude not run" no "$(ran)"
expect "A1 v2 missing security binary: says 无法检查钥匙串" yes "$(has "$OUT/stderr" '无法检查钥匙串')"
expect "A1 v2 missing security binary: says 找不到" yes "$(has "$OUT/stderr" '找不到')"
# 默认用 PATH 上的 security
ENVX=(FAKE_SECURITY_GH=0)
mkdir -p "$T/secbin"; cp "$FAKESEC" "$T/secbin/security"; chmod +x "$T/secbin/security"
run "$T/secbin:$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 default HARNESS_SECURITY=security from PATH: refused (3)" 3 "$(rc)"
expect "A1 v2 default security: full set queried" "$GHSET" "$(secset)"

# sandbox-check：macOS 也报钥匙串
ENVX=("${SEC[@]}" FAKE_SECURITY_GH=0)
run "$NODEPS" macos sandbox-check
expect "A1 sandbox-check macos + keychain: exit 3" 3 "$(rc)"
expect "A1 sandbox-check macos + keychain: prints the fix" yes "$(has "$OUT/stdout" '--insecure-storage')"
ENVX=("${SEC[@]}" FAKE_SECURITY_GH=0 HARNESS_ALLOW_KEYCHAIN=1)
run "$NODEPS" macos sandbox-check
expect "A1 sandbox-check allowed: exit 0" 0 "$(rc)"
expect "A1 sandbox-check allowed: warns HARNESS_ALLOW_KEYCHAIN=1" yes "$(has "$OUT/stdout" 'HARNESS_ALLOW_KEYCHAIN=1')"
ENVX=("${SEC[@]}")
run "$NODEPS" macos sandbox-check
expect "A1 sandbox-check clean macos: ok" "0 ok" "$(rc) $(cat "$OUT/stdout")"
ENVX=("${SEC[@]}" FAKE_SECURITY_GH=0)
run "$DEPS" linux sandbox-check
expect "A1 sandbox-check linux: ok, keychain not consulted" "0 ok 0" "$(rc) $(cat "$OUT/stdout") $(seccalls)"

# doctor：macOS 加「## 钥匙串」一段
FAKECRON="$T/fake-crontab"; printf '#!/bin/sh\nexit 1\n' > "$FAKECRON"; chmod +x "$FAKECRON"
doctor() {  # doctor PLATFORM <env…>   结果：$OUT/doc
  local plat="$1"; shift
  rm -rf "$OUT"; mkdir -p "$OUT"; : > "$SECLOG"
  (cd "$R" && env -i HOME="$HOMED" XDG_STATE_HOME="$XDG" PATH="$NODEPS" HARNESS_PLATFORM="$plat" HARNESS_CRONTAB="$FAKECRON" \
     HARNESS_GATE_CHANNEL=off FAKE_SECURITY_LOG="$SECLOG" "$@" "$PY3" "$SRC/bin/harness" doctor --repo "$R") > "$OUT/doc" 2> "$OUT/doc.err"
  echo $? > "$OUT/rc"
}
sec() { awk -v h="## $2" '$0==h{p=1;next} /^## /{p=0} p' "$1" 2>/dev/null | sed '/^[[:space:]]*$/d'; }
doctor macos "${SEC[@]}" FAKE_SECURITY_GH=0
expect "A1 doctor macos + keychain: exit 0" 0 "$(rc)"
expect "A1 doctor macos: 钥匙串 section right after 沙箱依赖" yes "$(grep '^## ' "$OUT/doc" | grep -A1 -x '## 沙箱依赖' | tail -1 | grep -qx '## 钥匙串' && echo yes || echo no)"
expect "A1 doctor keychain section names gh:github.com" yes "$(sec "$OUT/doc" 钥匙串 | grep -qF 'gh:github.com' && echo yes || echo no)"
expect "A1 doctor keychain section has the fix" yes "$(sec "$OUT/doc" 钥匙串 | grep -qF -- '--insecure-storage' && echo yes || echo no)"
expect "A1 doctor: 沙箱依赖 still ok (sandbox_problem unchanged)" ok "$(sec "$OUT/doc" 沙箱依赖)"
expect "A1 doctor: no -w / -g" 0 "$(grep -cE '(^| )-(w|g)( |$)' "$SECLOG" 2>/dev/null)"
expect "A1 doctor: no keychain attributes echoed" 0 "$(grep -c 'FAKE-KEYCHAIN-ATTR' "$OUT/doc" "$OUT/doc.err" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')"
doctor macos "${SEC[@]}" FAKE_SECURITY_GH=0 HARNESS_ALLOW_KEYCHAIN=1
expect "A1 doctor allowed: says HARNESS_ALLOW_KEYCHAIN=1 已放行" yes "$(sec "$OUT/doc" 钥匙串 | grep -F 'HARNESS_ALLOW_KEYCHAIN=1' | grep -qF '已放行' && echo yes || echo no)"
doctor macos "${SEC[@]}"
expect "A1 doctor clean keychain: section says ok" ok "$(sec "$OUT/doc" 钥匙串)"
doctor linux "${SEC[@]}" FAKE_SECURITY_GH=0
expect "A1 doctor linux: no 钥匙串 section" 0 "$(grep -cx '## 钥匙串' "$OUT/doc")"
expect "A1 doctor linux: security not called" 0 "$(seccalls)"

# ================================================================ A2：验证入口文件
# 进程内：verify_entry_paths(root)
vep() { HOOKS="$HOOKS" "$PY3" - "$1" <<'PY' 2>&1
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["HOOKS"])
import harness_lib as H
try:
    r = H.verify_entry_paths(Path(sys.argv[1]))
    ok = isinstance(r, list) and all(isinstance(x, str) for x in r) and r == sorted(set(r))
    print(("|".join(r)) if ok else "BAD:" + repr(r))
except Exception as e:
    print("EXC:" + type(e).__name__)
PY
}
vhas() { vep "$1" | tr '|' '\n' | grep -qx -- "$2" && echo yes || echo no; }
PYSET="conftest.py noxfile.py pyproject.toml pytest.ini setup.cfg tox.ini"
mkdir -p "$T/v"; for d in npm pnpm yarn make pyt pym tox nox cargo go none comm noh qc ws; do mkdir -p "$T/v/$d"; done
verify v/npm  'set -e
npm run test'
verify v/pnpm 'pnpm -r test'
verify v/yarn 'yarn test --ci'
verify v/make 'make check'
verify v/pyt  'pytest -q'
verify v/pym  'python3 -m unittest discover'
verify v/tox  'tox -e py'
verify v/nox  'nox -s tests'
verify v/cargo 'cargo test --all'
verify v/go   'go test ./...'
verify v/none 'bash -n scripts/x.sh
echo ok
exit 0'
verify v/comm '# npm run test   (disabled)
  # go test ./...
exit 0'
verify v/qc 'exit 0'; quick v/qc 'make lint'
verify v/ws 'npm test && npm run lint
pnpm test'
expect "A2 v2 verify_entry_paths: npm run test -> exactly the npm set" ".npmrc|.pnpmfile.cjs|.yarnrc|.yarnrc.yml|package.json" "$(vep "$T/v/npm")"
expect "A2 v2 verify_entry_paths: pnpm -> npm set" ".npmrc|.pnpmfile.cjs|.yarnrc|.yarnrc.yml|package.json" "$(vep "$T/v/pnpm")"
expect "A2 v2 verify_entry_paths: yarn -> npm set" ".npmrc|.pnpmfile.cjs|.yarnrc|.yarnrc.yml|package.json" "$(vep "$T/v/yarn")"
expect "A2 v2 verify_entry_paths: duplicates collapsed" ".npmrc|.pnpmfile.cjs|.yarnrc|.yarnrc.yml|package.json" "$(vep "$T/v/ws")"
expect "A2 verify_entry_paths: make -> Makefile" yes "$(vhas "$T/v/make" Makefile)"
expect "A2 verify_entry_paths: make -> GNUmakefile (make reads it first)" yes "$(vhas "$T/v/make" GNUmakefile)"
expect "A2 verify_entry_paths: make -> no package.json" no "$(vhas "$T/v/make" package.json)"
for f in $PYSET; do
  expect "A2 verify_entry_paths: pytest -> $f" yes "$(vhas "$T/v/pyt" "$f")"
  expect "A2 verify_entry_paths: python3 -m -> $f" yes "$(vhas "$T/v/pym" "$f")"
done
expect "A2 verify_entry_paths: tox -> tox.ini" yes "$(vhas "$T/v/tox" tox.ini)"
expect "A2 verify_entry_paths: nox -> noxfile.py" yes "$(vhas "$T/v/nox" noxfile.py)"
expect "A2 v2 verify_entry_paths: cargo -> Cargo.toml + .cargo/config(.toml)" ".cargo/config|.cargo/config.toml|Cargo.toml" "$(vep "$T/v/cargo")"
expect "A2 v2 verify_entry_paths: go test -> go.mod + go.work" "go.mod|go.work" "$(vep "$T/v/go")"
expect "A2 verify_entry_paths: no tool -> []" "" "$(vep "$T/v/none")"
expect "A2 verify_entry_paths: commented-out commands ignored" "" "$(vep "$T/v/comm")"
expect "A2 verify_entry_paths: no .harness -> [] (no error)" "" "$(vep "$T/v/noh")"
expect "A2 verify_entry_paths: quick-check.sh counts too (make)" yes "$(vhas "$T/v/qc" Makefile)"

# strict 配置：入口文件进 denyWrite（现有的）与 Edit/Write deny（全部）
mkrepo sn; printf '{"name":"demo"}\n' > "$T/sn/package.json"; verify sn 'npm run test'; commitall sn
mkrepo sp; printf '[project]\nname = "demo"\n' > "$T/sp/pyproject.toml"; verify sp 'python3 -m pytest -q'; commitall sp
mkrepo sm; printf 'check:\n\ttrue\n' > "$T/sm/Makefile"; verify sm 'exit 0'; quick sm 'make check'; commitall sm
mkrepo s0; printf '{"name":"demo"}\n' > "$T/s0/package.json"; verify s0 'exit 0'; commitall s0
ENVX=()
for n in sn sp sm s0; do R="$T/$n"; run "$DEPS" linux launch --strict --root "$R" -- -p hello; grab "$n"; done
R="$T/sn"
expect "A2 strict npm: package.json in sandbox denyWrite" yes "$(q "$T/s-sn.json" "in_dw('package.json')")"
expect "A2 strict npm: Edit/Write(package.json) denied" yes "$(q "$T/s-sn.json" "ew('package.json')")"
R="$T/sp"
expect "A2 strict pytest: pyproject.toml in denyWrite" yes "$(q "$T/s-sp.json" "in_dw('pyproject.toml')")"
expect "A2 strict pytest: Edit/Write(pyproject.toml) denied" yes "$(q "$T/s-sp.json" "ew('pyproject.toml')")"
expect "A2 strict pytest: absent pytest.ini still Edit/Write denied" yes "$(q "$T/s-sp.json" "ew('pytest.ini')")"
expect "A2 strict pytest: absent conftest.py still Edit/Write denied" yes "$(q "$T/s-sp.json" "ew('conftest.py')")"
expect "A2 strict pytest: absent pytest.ini NOT in denyWrite (no empty placeholder)" yes "$(q "$T/s-sp.json" "s is not None and not in_dw('pytest.ini')")"
expect "A2 strict pytest: absent pytest.ini placeholder not created" no "$([ -e "$T/sp/pytest.ini" ] && echo yes || echo no)"
R="$T/sm"
expect "A2 strict make (quick-check): Makefile in denyWrite" yes "$(q "$T/s-sm.json" "in_dw('Makefile')")"
expect "A2 strict make: Edit/Write(Makefile) denied" yes "$(q "$T/s-sm.json" "ew('Makefile')")"
R="$T/s0"
expect "A2 strict: package.json not referenced by verify.sh -> not in denyWrite" yes "$(q "$T/s-s0.json" "s is not None and not in_dw('package.json')")"
expect "A2 strict: package.json not referenced -> no Edit/Write deny" yes "$(q "$T/s-s0.json" "no_ew('package.json')")"
# worktree：主仓库的 verify.sh 推出的入口文件，在 worktree 与主仓库都拒绝
git -C "$T/sn" worktree add -q "$T/sn-wt" -b task/T-301-x 2>/dev/null
R="$T/sn-wt"; run "$DEPS" linux launch --strict --task T-301 --root "$R" -- -p hello; grab snwt
expect "A2 strict worktree: worktree package.json in denyWrite" yes "$(q "$T/s-snwt.json" "in_dw('package.json')")"
expect "A2 strict worktree: main package.json in denyWrite" yes "$(q "$T/s-snwt.json" "in_dw('package.json', '$T/sn')")"
expect "A2 strict worktree: worktree Edit/Write(package.json) denied" yes "$(q "$T/s-snwt.json" "ew('package.json')")"

# control_diff：入口文件改动命中
mkrepo cd; cd "$T/cd" || exit 1
printf '{"name":"demo"}\n' > package.json; printf 'all:\n\ttrue\n' > Makefile; printf '[package]\nname="x"\n' > Cargo.toml
printf 'module x\n' > go.mod; mkdir -p src; echo a > src/a.js
verify cd 'npm run test
make all
cargo test'
quick cd 'go vet ./...'
git add -A && git commit -qm init
br() { local name="$1"; shift; git checkout -q -b "$name" main && eval "$*" && git add -A && git commit -qm "$name" && git checkout -q -f main; }
br e-pkg      'printf "{\"name\":\"demo\",\"scripts\":{\"test\":\"echo bypass\"}}\n" > package.json'
br e-make     'printf "all:\n\techo bypass\n" > Makefile'
br e-gnumake  'printf "all:\n\techo bypass\n" > GNUmakefile'
br e-cargo    'echo "# x" >> Cargo.toml'
br e-gomod    'echo "// x" >> go.mod'
br e-src      'echo b >> src/a.js'
br e-strip    'printf "#!/usr/bin/env bash\nexit 0\n" > .harness/verify.sh; printf "{\"name\":\"x\"}\n" > package.json'
cd "$T"
cdl() {  # cdl <root> <args…> → $OUT/{rc,stdout}
  local r="$1"; shift
  rm -rf "$OUT"; mkdir -p "$OUT"
  ( cd "$T" && env -i HOME="$HOMED" PATH="$PATH" XDG_STATE_HOME="$XDG" "$PY3" "$LIB" control-diff "$@" --root "$r" ) > "$OUT/stdout" 2> "$OUT/stderr"
  echo $? > "$OUT/rc"
}
lines() { paste -sd'|' "$OUT/stdout" 2>/dev/null; }
for c in "e-pkg package.json" "e-make Makefile" "e-gnumake GNUmakefile" "e-cargo Cargo.toml" "e-gomod go.mod"; do
  set -- $c
  cdl "$T/cd" main "$1"
  expect "A2 control-diff $1: exit 1" 1 "$(rc)"
  expect "A2 control-diff $1: lists exactly $2" "$2" "$(lines)"
done
cdl "$T/cd" main e-src
expect "A2 control-diff src-only: exit 0" 0 "$(rc)"
cdl "$T/cd" main e-strip
expect "A2 control-diff: branch dropping npm from verify.sh still hits package.json" ".harness/verify.sh|package.json" "$(lines)"
# 入口文件新建（例如根目录 conftest.py / pytest.ini）也算
mkrepo cp; cd "$T/cp" || exit 1
printf '[project]\nname="x"\n' > pyproject.toml; verify cp 'pytest -q'; git add -A && git commit -qm init
br p-conftest 'printf "import os\n" > conftest.py'
br p-ini      'printf "[pytest]\naddopts = -p no:x\n" > pytest.ini'
br p-sub      'mkdir -p tests && printf "x = 1\n" > tests/helpers.py'
cd "$T"
cdl "$T/cp" main p-conftest
expect "A2 control-diff: new root conftest.py hits" "1 conftest.py" "$(rc) $(lines)"
cdl "$T/cp" main p-ini
expect "A2 control-diff: new pytest.ini hits" "1 pytest.ini" "$(rc) $(lines)"
cdl "$T/cp" main p-sub
expect "A2 control-diff: ordinary test helper does not hit" 0 "$(rc)"
# verify.sh 不引用 npm 时 package.json 不是控制路径
mkrepo c0; cd "$T/c0" || exit 1
printf '{"name":"demo"}\n' > package.json; verify c0 'exit 0'; git add -A && git commit -qm init
br z-pkg 'printf "{\"name\":\"other\"}\n" > package.json'
cd "$T"
cdl "$T/c0" main z-pkg
expect "A2 control-diff: package.json unreferenced by verify -> exit 0" 0 "$(rc)"
expect "A2 control_diff(): in-process hit" "package.json" \
  "$(HOOKS="$HOOKS" "$PY3" -c 'import os,sys; sys.path.insert(0,os.environ["HOOKS"]); import harness_lib as H; print("|".join(H.control_diff(sys.argv[1],"main","e-pkg")))' "$T/cd" 2>&1 | tail -1)"

# ================================================================ A3：claude.ai 连接器
R="$T/kc"
ENVX=(ENABLE_CLAUDEAI_MCP_SERVERS=true)
run "$DEPS" linux launch --strict --root "$R" -- -p hello
grab mcp
expect "A3 strict: env ENABLE_CLAUDEAI_MCP_SERVERS=false (overrides caller's true)" 1 "$(grep -cx 'ENABLE_CLAUDEAI_MCP_SERVERS=false' "$OUT/env" 2>/dev/null)"
expect "A3 strict: first arg still --settings" "--settings" "$(head -1 "$OUT/argv" 2>/dev/null)"
expect "A3 strict: argv after settings = user args then --strict-mcp-config" "-p|hello|--strict-mcp-config" "$(sed -n '3,$p' "$OUT/argv" 2>/dev/null | paste -sd'|')"
expect "A3 strict: --strict-mcp-config exactly once" 1 "$(grep -cx -- '--strict-mcp-config' "$OUT/argv" 2>/dev/null)"
# v2（§9）：通配 mcp__claude_ai_* 无效，改为 disableClaudeAiConnectors
expect "A3 v2 strict: settings disableClaudeAiConnectors true" yes "$(q "$T/s-mcp.json" "g('disableClaudeAiConnectors') is True")"
expect "A3 strict: permissions.deny has mcp__claude_ai_Gmail" yes "$(q "$T/s-mcp.json" "'mcp__claude_ai_Gmail' in PD()")"
ENVX=()
run "$DEPS" linux launch --strict --root "$R" -- -p hello -- extra
expect "A3 strict: flag goes before a -- in the claude args" "-p|hello|--strict-mcp-config|--|extra" "$(sed -n '3,$p' "$OUT/argv" 2>/dev/null | paste -sd'|')"
run "$DEPS" linux launch --strict --role plan --root "$R" -- -p /backlog-groom
grab mcpplan
expect "A3 plan role: ENABLE_CLAUDEAI_MCP_SERVERS=false" 1 "$(grep -cx 'ENABLE_CLAUDEAI_MCP_SERVERS=false' "$OUT/env" 2>/dev/null)"
expect "A3 plan role: --strict-mcp-config passed" 1 "$(grep -cx -- '--strict-mcp-config' "$OUT/argv" 2>/dev/null)"
expect "A3 v2 plan role: disableClaudeAiConnectors true" yes "$(q "$T/s-mcpplan.json" "g('disableClaudeAiConnectors') is True")"
run "$DEPS" linux launch --strict --print-settings --root "$R" -- -p hello
expect "A3 v2 --print-settings: disableClaudeAiConnectors and Gmail deny" yes "$(q "$OUT/stdout" "g('disableClaudeAiConnectors') is True and 'mcp__claude_ai_Gmail' in PD()")"
ENVX=(ENABLE_CLAUDEAI_MCP_SERVERS=true)
run "$NODEPS" linux launch --root "$R" -- -p hello
expect "A3 standard: no --strict-mcp-config" "-p|hello" "$(argvline)"
expect "A3 standard: caller's ENABLE_CLAUDEAI_MCP_SERVERS left alone" 1 "$(grep -cx 'ENABLE_CLAUDEAI_MCP_SERVERS=true' "$OUT/env" 2>/dev/null)"
ENVX=()
run "$NODEPS" linux launch --root "$R" -- -p hello
expect "A3 standard: ENABLE_CLAUDEAI_MCP_SERVERS not added" 0 "$(grep -c '^ENABLE_CLAUDEAI_MCP_SERVERS=' "$OUT/env" 2>/dev/null)"

# ================================================================ A4：locked_paths 硬边界
mkrepo lk; cd "$T/lk" || exit 1
mkdir -p src/core src/other docs .harness/tasks; echo a > src/core/a.py; echo o > src/other/o.py; echo L > LICENSE
echo a > docs/a.md; echo b > docs/b.txt; verify lk 'exit 0'
card() {  # card <file> <locked list>
  printf -- '---\nid: T-201\ntitle: x\nstatus: in_progress\nbranch: task/T-201-x\nlocked_paths: [%s]\nunlock: []\n---\n\n# T-201 x\n' "$2" > "$1"
}
card .harness/tasks/T-201-x.md 'src/core/**, LICENSE, docs/*.md'
git add -A && git commit -qm init
git worktree add -q "$T/lk-wt" -b task/T-201-x 2>/dev/null
WL="$T/lk-wt"
card "$WL/.harness/tasks/T-201-x.md" 'extra/**'      # Claude 改了自己的卡：去掉原锁、加了一项
mkdir -p "$WL/extra"; echo e > "$WL/extra/e.txt"
cd "$T"
R="$WL"; ENVX=()
run "$DEPS" linux launch --strict --task T-201 --root "$R" -- -p hello
expect "A4 strict --task: exits 0" 0 "$(rc)"
grab lk; SL="$T/s-lk.json"
expect "A4 src/core/** -> denyWrite dir form //wt/src/core" yes "$(q "$SL" "ab(R, 'src/core') in DW()")"
expect "A4 src/core/** -> Edit/Write(//wt/src/core/**)" yes "$(q "$SL" "ew('src/core/**')")"
expect "A4 LICENSE -> denyWrite" yes "$(q "$SL" "ab(R, 'LICENSE') in DW()")"
expect "A4 LICENSE -> Edit/Write deny" yes "$(q "$SL" "ew('LICENSE')")"
expect "A4 docs/*.md -> existing docs/a.md in denyWrite" yes "$(q "$SL" "ab(R, 'docs/a.md') in DW()")"
expect "A4 docs/*.md -> docs/b.txt not in denyWrite" yes "$(q "$SL" "s is not None and ab(R, 'docs/b.txt') not in DW()")"
expect "A4 docs/*.md -> whole docs dir not locked" yes "$(q "$SL" "s is not None and ab(R, 'docs') not in DW()")"
expect "A4 docs/*.md -> Edit/Write(//wt/docs/*.md) glob form" yes "$(q "$SL" "ew('docs/*.md')")"
expect "A4 main card's locks kept although worktree card dropped them" yes "$(q "$SL" "ab(R, 'src/core') in DW() and ab(R, 'LICENSE') in DW()")"
expect "A4 worktree card's extra lock added too (union)" yes "$(q "$SL" "ab(R, 'extra') in DW() and ew('extra/**')")"
expect "A4 unlocked src/other not denied" yes "$(q "$SL" "s is not None and ab(R, 'src/other') not in DW() and no_ew('src/other/**')")"
run "$DEPS" linux launch --strict --root "$R" -- -p hello
grab lknotask
expect "A4 without --task: locked_paths not applied" yes "$(q "$T/s-lknotask.json" "s is not None and ab(R, 'src/core') not in DW() and no_ew('src/core/**')")"
run "$DEPS" linux launch --strict --task T-999 --root "$R" -- -p hello
expect "A4 --task with no card: still launches" 0 "$(rc)"

# control-diff --task：改 locked_paths 的分支命中
cd "$T/lk" || exit 1
br l-core   'echo b >> src/core/a.py'
br l-strip  'sed -i.bak "s#^locked_paths: .*#locked_paths: []#" .harness/tasks/T-201-x.md; rm -f .harness/tasks/*.bak; echo X >> LICENSE'
br l-add    'sed -i.bak "s#^locked_paths: .*#locked_paths: [src/core/**, src/other/**]#" .harness/tasks/T-201-x.md; rm -f .harness/tasks/*.bak; echo p >> src/other/o.py'
br l-docmd  'echo c >> docs/a.md'
br l-doctxt 'echo c >> docs/b.txt'
br l-free   'mkdir -p src/new && echo n > src/new/n.py'
cd "$T"
cdl "$T/lk" main l-core --task T-201
expect "A4 control-diff --task: locked src/core/a.py hits" "1 src/core/a.py" "$(rc) $(lines)"
cdl "$T/lk" main l-core
expect "A4 control-diff without --task: locked path not a control path" "0 " "$(rc) $(lines)"
cdl "$T/lk" main l-core --task T-777
expect "A4 control-diff other task: no locked hit" 0 "$(rc)"
cdl "$T/lk" main l-strip --task T-201
expect "A4 control-diff: branch that removed its locked_paths still hits LICENSE" yes "$([ "$(rc)" = 1 ] && grep -qx 'LICENSE' "$OUT/stdout" && echo yes || echo no)"
cdl "$T/lk" main l-add --task T-201
expect "A4 control-diff: lock added on the branch card also counts" yes "$([ "$(rc)" = 1 ] && grep -qx 'src/other/o.py' "$OUT/stdout" && echo yes || echo no)"
cdl "$T/lk" main l-docmd --task T-201
expect "A4 control-diff: docs/a.md matches docs/*.md" "1 docs/a.md" "$(rc) $(lines)"
cdl "$T/lk" main l-doctxt --task T-201
expect "A4 control-diff: docs/b.txt does not match docs/*.md" 0 "$(rc)"
cdl "$T/lk" main l-free --task T-201
expect "A4 control-diff: unlocked new file passes" 0 "$(rc)"
cdl "$T/lk" main l-core --task
expect "A4 control-diff: --task without value -> exit 2" 2 "$(rc)"
cdl "$T/lk" main l-core --task foo
expect "A4 control-diff: --task not T-xxx -> exit 2" 2 "$(rc)"
expect "A4 control_diff(task=) in-process" "src/core/a.py" \
  "$(HOOKS="$HOOKS" "$PY3" -c 'import os,sys; sys.path.insert(0,os.environ["HOOKS"]); import harness_lib as H; print("|".join(H.control_diff(sys.argv[1],"main","l-core",task="T-201")))' "$T/lk" 2>&1 | tail -1)"
# 主仓库工作区的卡（未提交的新锁）也算
sed -i.bak 's#^locked_paths: .*#locked_paths: [src/core/**, LICENSE, docs/*.md, src/new/**]#' "$T/lk/.harness/tasks/T-201-x.md"; rm -f "$T/lk/.harness/tasks/"*.bak
cdl "$T/lk" main l-free --task T-201
expect "A4 control-diff: main working-tree card's locked_paths count" "1 src/new/n.py" "$(rc) $(lines)"

# ################################################################ 接口约定 v2（第 2 轮）
# ================================================================ A1 v2：更多钥匙串项、失败即拒绝
R="$T/kc"
ENVX=("${SEC[@]}" "FAKE_SECURITY_ITEMS=generic:git:https://github.com")
run "$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 v2 Git Credential Manager item: refused (3)" 3 "$(rc)"
expect "A1 v2 GCM: names git:https://github.com" yes "$(has "$OUT/stderr" 'git:https://github.com')"
expect "A1 v2 GCM: fix mentions credential.credentialStore" yes "$(has "$OUT/stderr" 'credential.credentialStore')"
ENVX=("${SEC[@]}" "FAKE_SECURITY_ITEMS=generic:Claude Code-credentials")
run "$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 v2 Claude Code-credentials only: warning, strict still starts (0)" 0 "$(rc)"
expect "A1 v2 Claude Code-credentials: claude ran" yes "$(ran)"
expect "A1 v2 Claude Code-credentials: warning names the item" yes "$(has "$OUT/stderr" 'Claude Code-credentials')"
expect "A1 v2 Claude Code-credentials: suggests CLAUDE_CODE_OAUTH_TOKEN" yes "$(has "$OUT/stderr" 'CLAUDE_CODE_OAUTH_TOKEN')"
expect "A1 v2 Claude item queried as one argument" 1 "$(grep -cx 'find-generic-password -s Claude Code-credentials' "$SECLOG" 2>/dev/null)"
run "$NODEPS" macos sandbox-check
expect "A1 v2 sandbox-check with Claude item: exit 0 + CLAUDE_CODE_OAUTH_TOKEN hint" "0 yes" "$(rc) $(has "$OUT/stdout" 'CLAUDE_CODE_OAUTH_TOKEN')"
doctor macos "${SEC[@]}" "FAKE_SECURITY_ITEMS=generic:Claude Code-credentials"
expect "A1 v2 doctor: Claude item -> CLAUDE_CODE_OAUTH_TOKEN hint in 钥匙串" yes "$(sec "$OUT/doc" 钥匙串 | grep -qF 'CLAUDE_CODE_OAUTH_TOKEN' && echo yes || echo no)"
# GitHub Enterprise：gh 的 hosts.yml 里的主机
mkdir -p "$T/ghcfg"; printf 'github.com:\n    user: a\nghe.corp.example:\n    user: b\n    git_protocol: https\n' > "$T/ghcfg/hosts.yml"
ENVX=("${SEC[@]}" GH_CONFIG_DIR="$T/ghcfg" "FAKE_SECURITY_ITEMS=generic:gh:ghe.corp.example")
run "$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 v2 GHE host from hosts.yml: gh:<host> found -> refused (3)" 3 "$(rc)"
expect "A1 v2 GHE: names gh:ghe.corp.example" yes "$(has "$OUT/stderr" 'gh:ghe.corp.example')"
expect "A1 v2 GHE: fix uses --hostname" yes "$(has "$OUT/stderr" '--hostname')"
for l in 'find-generic-password -s gh:ghe.corp.example' 'find-internet-password -s ghe.corp.example' 'find-generic-password -s git:https://ghe.corp.example'; do
  expect "A1 v2 GHE queried: $l" 1 "$(grep -cxF "$l" "$SECLOG" 2>/dev/null)"
done
expect "A1 v2 GHE: hosts.yml sub-keys (user) not treated as hosts" 0 "$(grep -c -- '-s user\|-s gh:user\|git_protocol' "$SECLOG" 2>/dev/null)"
expect "A1 v2 GHE: still no -w / -g" 0 "$(grep -cE '(^| )-(w|g)( |$)' "$SECLOG" 2>/dev/null)"
# 本仓库 origin 的主机（ssh 与 https 写法）
mkrepo kcs; printf 'x\n' > "$T/kcs/README"; commitall kcs; git -C "$T/kcs" remote add origin git@ghe2.example.org:org/repo.git
mkrepo kch; printf 'x\n' > "$T/kch/README"; commitall kch; git -C "$T/kch" remote add origin https://ghe3.example/org/repo.git
ENVX=("${SEC[@]}" "FAKE_SECURITY_ITEMS=internet:ghe2.example.org")
R="$T/kcs"; run "$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 v2 origin git@host: internet password for host -> refused (3)" 3 "$(rc)"
expect "A1 v2 origin git@host: gh:<host> queried" 1 "$(grep -cxF 'find-generic-password -s gh:ghe2.example.org' "$SECLOG" 2>/dev/null)"
ENVX=("${SEC[@]}")
R="$T/kch"; run "$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 v2 origin https://host: clean -> starts" 0 "$(rc)"
expect "A1 v2 origin https://host: git:https://<host> queried" 1 "$(grep -cxF 'find-generic-password -s git:https://ghe3.example' "$SECLOG" 2>/dev/null)"
R="$T/kc"
# 失败即拒绝：44 以外的退出码、超时
ENVX=("${SEC[@]}" FAKE_SECURITY_RC=51)
run "$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 v2 security exit 51: refused (3)" 3 "$(rc)"
expect "A1 v2 exit 51: claude not run" no "$(ran)"
expect "A1 v2 exit 51: says 无法检查钥匙串" yes "$(has "$OUT/stderr" '无法检查钥匙串')"
expect "A1 v2 exit 51: names the exit code" yes "$(has "$OUT/stderr" '51')"
ENVX=("${SEC[@]}" FAKE_SECURITY_RC=51 HARNESS_ALLOW_KEYCHAIN=1)
run "$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 v2 exit 51 + HARNESS_ALLOW_KEYCHAIN=1: starts with a warning" "0 yes" "$(rc) $(has "$OUT/stderr" 'HARNESS_ALLOW_KEYCHAIN=1')"
ENVX=("${SEC[@]}" FAKE_SECURITY_RC=1)
run "$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 v2 security exit 1: refused (3)" 3 "$(rc)"
ENVX=("${SEC[@]}" FAKE_SECURITY_SLEEP=3 HARNESS_SECURITY_TIMEOUT=1)
run "$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 v2 security hangs: refused (3)" 3 "$(rc)"
expect "A1 v2 security hangs: says 超时" yes "$(has "$OUT/stderr" '超时')"
ENVX=("${SEC[@]}" FAKE_SECURITY_RC=51)
run "$NODEPS" macos sandbox-check
expect "A1 v2 sandbox-check: check error -> exit 3" 3 "$(rc)"
doctor macos "${SEC[@]}" FAKE_SECURITY_RC=51
expect "A1 v2 doctor: check error still exit 0" 0 "$(rc)"
expect "A1 v2 doctor: 钥匙串 says 无法检查钥匙串" yes "$(sec "$OUT/doc" 钥匙串 | grep -qF '无法检查钥匙串' && echo yes || echo no)"
ENVX=()

# ================================================================ A2 v2：入口表扩充、cd / -C / --prefix / -c、跟进脚本
for d in cdweb cdline cdreset mkC prefix prefix2 pyc follow dot src twolevel nonlit dotdot; do mkdir -p "$T/v/$d"; done
verify v/cdweb 'cd web && npm test'
verify v/cdline 'set -e
cd api
pytest -q'
verify v/cdreset 'cd "$(git rev-parse --show-toplevel)"
npm test'
verify v/mkC 'make -C sub check'
verify v/prefix 'npm --prefix web run test'
verify v/prefix2 'pnpm --prefix=app test'
verify v/pyc 'pytest -c ci/pytest.ini -q'
verify v/follow 'bash tools/check.sh'; mkdir -p "$T/v/follow/tools"; printf 'cargo test\n' > "$T/v/follow/tools/check.sh"
verify v/dot './ci.sh'; printf '#!/bin/sh\ngo test ./...\n' > "$T/v/dot/ci.sh"
verify v/src 'source env.sh
exit 0'; printf 'make all\n' > "$T/v/src/env.sh"
verify v/twolevel 'bash a.sh'; printf 'bash b.sh\n' > "$T/v/twolevel/a.sh"; printf 'cargo test\n' > "$T/v/twolevel/b.sh"
verify v/nonlit 'bash "$X"
exit 0'
verify v/dotdot 'cd ../other && npm test'
for f in .npmrc .yarnrc .yarnrc.yml .pnpmfile.cjs; do expect "A2 v2 npm -> $f" yes "$(vhas "$T/v/npm" "$f")"; done
expect "A2 v2 pytest -> .pytest.ini" yes "$(vhas "$T/v/pyt" .pytest.ini)"
expect "A2 v2 pytest -> **/conftest.py" yes "$(vhas "$T/v/pyt" '**/conftest.py')"
expect "A2 v2 python3 -m unittest -> unittest.py (shadowing)" yes "$(vhas "$T/v/pym" unittest.py)"
expect "A2 v2 python3 -m unittest -> unittest/**" yes "$(vhas "$T/v/pym" 'unittest/**')"
expect "A2 v2 cd web && npm test -> web/package.json" yes "$(vhas "$T/v/cdweb" web/package.json)"
expect "A2 v2 cd web && npm test -> web/.npmrc" yes "$(vhas "$T/v/cdweb" web/.npmrc)"
expect "A2 v2 cd on its own line carries to later lines (api/pyproject.toml)" yes "$(vhas "$T/v/cdline" api/pyproject.toml)"
expect "A2 v2 cd api -> api/conftest.py" yes "$(vhas "$T/v/cdline" api/conftest.py)"
expect "A2 v2 cd \"\$(...)\" resets to root -> package.json" yes "$(vhas "$T/v/cdreset" package.json)"
expect "A2 v2 make -C sub -> sub/Makefile" yes "$(vhas "$T/v/mkC" sub/Makefile)"
expect "A2 v2 npm --prefix web -> web/package.json" yes "$(vhas "$T/v/prefix" web/package.json)"
expect "A2 v2 pnpm --prefix=app -> app/package.json" yes "$(vhas "$T/v/prefix2" app/package.json)"
expect "A2 v2 pytest -c ci/pytest.ini -> ci/pytest.ini" yes "$(vhas "$T/v/pyc" ci/pytest.ini)"
expect "A2 v2 bash tools/check.sh -> the script itself" yes "$(vhas "$T/v/follow" tools/check.sh)"
expect "A2 v2 followed script's cargo -> Cargo.toml" yes "$(vhas "$T/v/follow" Cargo.toml)"
expect "A2 v2 ./ci.sh -> ci.sh" yes "$(vhas "$T/v/dot" ci.sh)"
expect "A2 v2 ./ci.sh's go test -> go.mod" yes "$(vhas "$T/v/dot" go.mod)"
expect "A2 v2 source env.sh -> env.sh and Makefile" "yes yes" "$(vhas "$T/v/src" env.sh) $(vhas "$T/v/src" Makefile)"
expect "A2 v2 one level only: a.sh listed" yes "$(vhas "$T/v/twolevel" a.sh)"
expect "A2 v2 one level only: b.sh's cargo not followed" no "$(vhas "$T/v/twolevel" Cargo.toml)"
expect "A2 v2 non-literal script path ignored -> []" "" "$(vep "$T/v/nonlit")"
expect "A2 v2 bash -n (syntax check) is not an invocation -> []" "" "$(vep "$T/v/none")"
expect "A2 v2 no entry escapes the repo (..)" no "$(vep "$T/v/dotdot" | tr '|' '\n' | grep -q '\.\.' && echo yes || echo no)"

# strict 配置
mkdir -p "$T/sp/tests"; echo 'import pytest' > "$T/sp/tests/conftest.py"; commitall sp conftest
mkrepo sw; mkdir -p "$T/sw/web"; printf '{"name":"w"}\n' > "$T/sw/web/package.json"; verify sw 'cd web && npm test'; commitall sw
mkrepo sf; mkdir -p "$T/sf/tools"; printf 'npm test\n' > "$T/sf/tools/check.sh"; printf '{"name":"f"}\n' > "$T/sf/package.json"; verify sf 'bash tools/check.sh'; commitall sf
mkrepo smod; mkdir -p "$T/smod/mytool"; echo 'x=1' > "$T/smod/mytool/__init__.py"; verify smod 'python3 -m mytool check'; commitall smod
for n in sp sw sf smod; do R="$T/$n"; run "$DEPS" linux launch --strict --root "$R" -- -p hello; grab "v2$n"; done
R="$T/sp"
expect "A2 v2 strict: existing tests/conftest.py in denyWrite" yes "$(q "$T/s-v2sp.json" "in_dw('tests/conftest.py')")"
expect "A2 v2 strict: Edit/Write(**/conftest.py) glob" yes "$(q "$T/s-v2sp.json" "ew('**/conftest.py')")"
R="$T/sw"
expect "A2 v2 strict cd web: web/package.json in denyWrite" yes "$(q "$T/s-v2sw.json" "in_dw('web/package.json')")"
expect "A2 v2 strict cd web: Edit/Write(web/.npmrc)" yes "$(q "$T/s-v2sw.json" "ew('web/.npmrc')")"
R="$T/sf"
expect "A2 v2 strict: followed script tools/check.sh in denyWrite" yes "$(q "$T/s-v2sf.json" "in_dw('tools/check.sh')")"
expect "A2 v2 strict: followed script's package.json in denyWrite" yes "$(q "$T/s-v2sf.json" "in_dw('package.json')")"
R="$T/smod"
expect "A2 v2 strict: python -m mytool -> dir mytool in denyWrite" yes "$(q "$T/s-v2smod.json" "ab(R, 'mytool') in DW()")"
expect "A2 v2 strict: Edit/Write(mytool/**) and (mytool.py)" yes "$(q "$T/s-v2smod.json" "ew('mytool/**') and ew('mytool.py')")"
expect "A2 v2 strict: absent mytool.py not in denyWrite" yes "$(q "$T/s-v2smod.json" "s is not None and ab(R, 'mytool.py') not in DW()")"

# control-diff
cd "$T/cd" || exit 1
br e-npmrc   'echo "script-shell=/tmp/evil" > .npmrc'
br e-cargocfg 'mkdir -p .cargo && printf "[build]\nrustc-wrapper=\"/tmp/evil\"\n" > .cargo/config.toml'
br e-gowork  'printf "go 1.22\nuse ./evil\n" > go.work'
cd "$T/cp" || exit 1
br p-subconf 'mkdir -p tests && printf "import os\n" > tests/conftest.py'
br p-dotini  'printf "[pytest]\n" > .pytest.ini'
cd "$T"
for c in "cd e-npmrc .npmrc" "cd e-cargocfg .cargo/config.toml" "cd e-gowork go.work" "cp p-subconf tests/conftest.py" "cp p-dotini .pytest.ini"; do
  set -- $c
  cdl "$T/$1" main "$2"
  expect "A2 v2 control-diff $2: hits $3" "1 $3" "$(rc) $(lines)"
done
mkrepo cm; cd "$T/cm" || exit 1
mkdir -p mytool src; echo 'x=1' > mytool/__init__.py; echo a > src/a.py; verify cm 'python3 -m mytool check'; git add -A && git commit -qm init
br m-pkg    'echo "y=2" >> mytool/__init__.py'
br m-shadow 'echo "print(1)" > mytool.py'
br m-src    'echo b >> src/a.py'
mkrepo cs; cd "$T/cs" || exit 1
mkdir -p tools; printf 'npm test\n' > tools/check.sh; printf '{"name":"s"}\n' > package.json; verify cs 'bash tools/check.sh'; git add -A && git commit -qm init
br s-script 'echo "exit 0" > tools/check.sh'
br s-pkg    'printf "{\"name\":\"s\",\"scripts\":{\"test\":\"true\"}}\n" > package.json'
mkrepo cw; cd "$T/cw" || exit 1
mkdir -p web; printf '{"name":"w"}\n' > web/package.json; verify cw 'cd web && npm test'; git add -A && git commit -qm init
br w-pkg 'printf "{\"name\":\"w\",\"scripts\":{\"test\":\"true\"}}\n" > web/package.json'
cd "$T"
cdl "$T/cm" main m-pkg;    expect "A2 v2 control-diff python -m mytool: mytool/__init__.py hits" "1 mytool/__init__.py" "$(rc) $(lines)"
cdl "$T/cm" main m-shadow; expect "A2 v2 control-diff: new root mytool.py hits" "1 mytool.py" "$(rc) $(lines)"
cdl "$T/cm" main m-src;    expect "A2 v2 control-diff: unrelated src change passes" 0 "$(rc)"
cdl "$T/cs" main s-script; expect "A2 v2 control-diff: followed script edited hits" "1 tools/check.sh" "$(rc) $(lines)"
cdl "$T/cs" main s-pkg;    expect "A2 v2 control-diff: package.json used by followed script hits" "1 package.json" "$(rc) $(lines)"
cdl "$T/cw" main w-pkg;    expect "A2 v2 control-diff: cd web -> web/package.json hits" "1 web/package.json" "$(rc) $(lines)"

# stray-entries：worktree 里未跟踪 / 被忽略的入口文件
mkrepo st; cd "$T/st" || exit 1
printf 'check:\n\ttrue\n' > Makefile; printf '{"name":"st"}\n' > package.json; printf '.npmrc\n' > .gitignore; mkdir -p src
verify st 'make check
npm test'; git add -A && git commit -qm init
cd "$T"
stray() { rm -rf "$OUT"; mkdir -p "$OUT"; (cd "$T" && env -i HOME="$HOMED" PATH="$PATH" XDG_STATE_HOME="$XDG" "$PY3" "$LIB" stray-entries --root "$1") > "$OUT/stdout" 2> "$OUT/stderr"; echo $? > "$OUT/rc"; }
stray "$T/st"
expect "A2 v2 stray-entries: clean worktree -> exit 0, nothing listed" "0 " "$(rc) $(lines)"
echo 'x' > "$T/st/src/notes.txt"
stray "$T/st"
expect "A2 v2 stray-entries: unrelated untracked file ignored" "0 " "$(rc) $(lines)"
printf 'all:\n\techo bypass\n' > "$T/st/GNUmakefile"
stray "$T/st"
expect "A2 v2 stray-entries: untracked GNUmakefile -> exit 1, listed" "1 GNUmakefile" "$(rc) $(lines)"
echo 'script-shell=/tmp/evil' > "$T/st/.npmrc"
stray "$T/st"
expect "A2 v2 stray-entries: ignored .npmrc listed too" yes "$([ "$(rc)" = 1 ] && grep -qx '.npmrc' "$OUT/stdout" && echo yes || echo no)"

# doctor：表外运行器
mkrepo dg; verify dg './gradlew test'; printf '#!/bin/sh\n' > "$T/dg/gradlew"; commitall dg
mkrepo dm; mkdir -p "$T/dm/ci"; verify dm 'bash ci/run.sh'; printf 'mvn -q verify\n' > "$T/dm/ci/run.sh"; commitall dm
R="$T/dg"; doctor linux
expect "A2 v2 doctor: unknown runner -> 验证入口 section" 1 "$(grep -cx '## 验证入口' "$OUT/doc")"
expect "A2 v2 doctor: names gradle" yes "$(sec "$OUT/doc" 验证入口 | grep -q 'gradle' && echo yes || echo no)"
expect "A2 v2 doctor: says not protected (没有被保护)" yes "$(sec "$OUT/doc" 验证入口 | grep -qF '没有被保护' && echo yes || echo no)"
R="$T/dm"; doctor linux
expect "A2 v2 doctor: runner inside followed script (mvn) reported" yes "$(sec "$OUT/doc" 验证入口 | grep -q 'mvn' && echo yes || echo no)"
R="$T/sn"; doctor linux
expect "A2 v2 doctor: known runner only -> no 验证入口 section" 0 "$(grep -cx '## 验证入口' "$OUT/doc")"
expect "A2 v2 doctor: still exit 0" 0 "$(rc)"

# ================================================================ A3 v2：disableClaudeAiConnectors 只在 strict
R="$T/kc"; ENVX=()
run "$DEPS" linux launch --strict --role plan --print-settings --root "$R" -- -p x
expect "A3 v2 plan --print-settings: disableClaudeAiConnectors true" yes "$(q "$OUT/stdout" "g('disableClaudeAiConnectors') is True")"

# ================================================================ A4 v2：标量 locked_paths；root == main 时 HEAD 的卡也算
mkrepo ls; cd "$T/ls" || exit 1
mkdir -p src/x .harness/tasks; echo a > src/x/a.py; verify ls 'exit 0'
printf -- '---\nid: T-212\ntitle: x\nstatus: in_progress\nbranch: task/T-212-x\nlocked_paths: src/x/**\n---\n\n# T-212\n' > .harness/tasks/T-212-x.md
git add -A && git commit -qm init
br ls-x 'echo b >> src/x/a.py'
git worktree add -q "$T/ls-wt" -b task/T-212-x 2>/dev/null
cd "$T"
R="$T/ls-wt"; run "$DEPS" linux launch --strict --task T-212 --root "$R" -- -p hello; grab lsc
expect "A4 v2 scalar locked_paths: src/x in denyWrite" yes "$(q "$T/s-lsc.json" "ab(R, 'src/x') in DW()")"
expect "A4 v2 scalar locked_paths: Edit/Write(src/x/**)" yes "$(q "$T/s-lsc.json" "ew('src/x/**')")"
cdl "$T/ls" main ls-x --task T-212
expect "A4 v2 scalar locked_paths: control-diff hits" "1 src/x/a.py" "$(rc) $(lines)"
mkrepo lm; cd "$T/lm" || exit 1
mkdir -p src/core .harness/tasks; echo a > src/core/a.py; verify lm 'exit 0'
card() { printf -- '---\nid: T-213\ntitle: x\nstatus: in_progress\nlocked_paths: [%s]\n---\n\n# T-213\n' "$2" > "$1"; }
card .harness/tasks/T-213-x.md 'src/core/**'; git add -A && git commit -qm init
card .harness/tasks/T-213-x.md ''            # 工作区的卡被改成不锁（未提交）
cd "$T"
R="$T/lm"; run "$DEPS" linux launch --strict --task T-213 --root "$R" -- -p hello; grab lmc
expect "A4 v2 root==main: HEAD card's lock kept (src/core in denyWrite)" yes "$(q "$T/s-lmc.json" "ab(R, 'src/core') in DW()")"
expect "A4 v2 root==main: Edit/Write(src/core/**)" yes "$(q "$T/s-lmc.json" "ew('src/core/**')")"

# ================================================================ A4 v2：gate_github.push_assets_ctl 带任务号
mkrepo pa; cd "$T/pa" || exit 1
mkdir -p src/locked src/free .harness/tasks .harness/gates; echo a > src/locked/a.txt; echo f > src/free/f.txt; verify pa 'exit 0'
printf -- '---\nid: T-205\ntitle: x\nstatus: review\nbranch: task/T-205-x\nlocked_paths: [src/locked/**]\n---\n\n# T-205\n' > .harness/tasks/T-205-x.md
printf -- '---\nid: T-206\ntitle: y\nstatus: review\nbranch: task/T-206-y\nlocked_paths: [src/locked/**]\n---\n\n# T-206\n' > .harness/tasks/T-206-y.md
git add -A && git commit -qm init
git init -q --bare "$T/pa-origin.git"; git remote add origin "$T/pa-origin.git"; git push -q origin main 2>/dev/null
git checkout -q -b task/T-205-x main; echo hacked >> src/locked/a.txt; mkdir -p .harness/gates/G-T205-1; echo s > .harness/gates/G-T205-1/shot.txt
git add -A && git commit -qm T-205 && git checkout -q -f main
git checkout -q -b task/T-206-y main; echo ok >> src/free/f.txt; mkdir -p .harness/gates/G-T206-1; echo s > .harness/gates/G-T206-1/shot.txt
git add -A && git commit -qm T-206 && git checkout -q -f main
cd "$T"
pac() { (cd "$T/pa" && env -u HARNESS_GATE_PUSH_ASSETS HOOKS="$HOOKS" HOME="$HOMED" XDG_STATE_HOME="$XDG" "$PY3" -c 'import os,sys; sys.path.insert(0,os.environ["HOOKS"]); from pathlib import Path; import gate_github as G; print(len(G.push_assets_ctl(Path(sys.argv[1]), sys.argv[2], sys.argv[3])))' "$T/pa" "$1" "$2") > "$OUT/pa.$1" 2>&1; }
pac G-T205-1 task/T-205-x; pac G-T206-1 task/T-206-y
expect "A4 v2 push_assets_ctl: branch touching its locked_paths not pushed" "" "$(git --git-dir="$T/pa-origin.git" branch --list 'task/T-205-x')"
expect "A4 v2 push_assets_ctl: clean branch still pushed (control)" "task/T-206-y" "$(git --git-dir="$T/pa-origin.git" branch --list 'task/T-206-y' | tr -d ' *')"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
