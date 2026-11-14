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
expect "A1 security called exactly twice" 2 "$(seccalls)"
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
expect "A1 clean keychain: both items were checked" 2 "$(seccalls)"

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
expect "A1 missing security binary: treated as absent, strict runs" 0 "$(rc)"
# 默认用 PATH 上的 security
ENVX=(FAKE_SECURITY_GH=0)
mkdir -p "$T/secbin"; cp "$FAKESEC" "$T/secbin/security"; chmod +x "$T/secbin/security"
run "$T/secbin:$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A1 default HARNESS_SECURITY=security from PATH: refused (3)" 3 "$(rc)"
expect "A1 default security: called" 2 "$(seccalls)"

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
expect "A2 verify_entry_paths: npm run test -> exactly package.json" "package.json" "$(vep "$T/v/npm")"
expect "A2 verify_entry_paths: pnpm -> package.json" "package.json" "$(vep "$T/v/pnpm")"
expect "A2 verify_entry_paths: yarn -> package.json" "package.json" "$(vep "$T/v/yarn")"
expect "A2 verify_entry_paths: duplicates collapsed" "package.json" "$(vep "$T/v/ws")"
expect "A2 verify_entry_paths: make -> Makefile" yes "$(vhas "$T/v/make" Makefile)"
expect "A2 verify_entry_paths: make -> GNUmakefile (make reads it first)" yes "$(vhas "$T/v/make" GNUmakefile)"
expect "A2 verify_entry_paths: make -> no package.json" no "$(vhas "$T/v/make" package.json)"
for f in $PYSET; do
  expect "A2 verify_entry_paths: pytest -> $f" yes "$(vhas "$T/v/pyt" "$f")"
  expect "A2 verify_entry_paths: python3 -m -> $f" yes "$(vhas "$T/v/pym" "$f")"
done
expect "A2 verify_entry_paths: tox -> tox.ini" yes "$(vhas "$T/v/tox" tox.ini)"
expect "A2 verify_entry_paths: nox -> noxfile.py" yes "$(vhas "$T/v/nox" noxfile.py)"
expect "A2 verify_entry_paths: cargo -> exactly Cargo.toml" "Cargo.toml" "$(vep "$T/v/cargo")"
expect "A2 verify_entry_paths: go test -> exactly go.mod" "go.mod" "$(vep "$T/v/go")"
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
expect "A3 strict: permissions.deny has mcp__claude_ai_*" yes "$(q "$T/s-mcp.json" "'mcp__claude_ai_*' in PD()")"
expect "A3 strict: permissions.deny has mcp__claude_ai_Gmail" yes "$(q "$T/s-mcp.json" "'mcp__claude_ai_Gmail' in PD()")"
ENVX=()
run "$DEPS" linux launch --strict --root "$R" -- -p hello -- extra
expect "A3 strict: flag goes before a -- in the claude args" "-p|hello|--strict-mcp-config|--|extra" "$(sed -n '3,$p' "$OUT/argv" 2>/dev/null | paste -sd'|')"
run "$DEPS" linux launch --strict --role plan --root "$R" -- -p /backlog-groom
grab mcpplan
expect "A3 plan role: ENABLE_CLAUDEAI_MCP_SERVERS=false" 1 "$(grep -cx 'ENABLE_CLAUDEAI_MCP_SERVERS=false' "$OUT/env" 2>/dev/null)"
expect "A3 plan role: --strict-mcp-config passed" 1 "$(grep -cx -- '--strict-mcp-config' "$OUT/argv" 2>/dev/null)"
expect "A3 plan role: deny has mcp__claude_ai_*" yes "$(q "$T/s-mcpplan.json" "'mcp__claude_ai_*' in PD()")"
run "$DEPS" linux launch --strict --print-settings --root "$R" -- -p hello
expect "A3 --print-settings shows the connector deny" yes "$(q "$OUT/stdout" "'mcp__claude_ai_*' in PD() and 'mcp__claude_ai_Gmail' in PD()")"
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

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
