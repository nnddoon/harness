#!/usr/bin/env bash
# T-008 验收：统一启动器 `harness_lib.py launch`（strict 配置、清理凭证、沙箱依赖检查）。
# 用假 claude（HARNESS_CLAUDE）记录收到的 argv 与环境；HARNESS_PLATFORM 覆盖平台检测。
# 按任务卡「接口约定」与「接口约定 v2」（对抗审查第 1 轮后修订）。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$SRC/.claude/hooks/harness_lib.py"
HOOKS="$SRC/.claude/hooks"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-launch.XXXXXX")"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
has() { grep -qF -- "$2" "$1" 2>/dev/null && echo yes || echo no; }
hasenv() { grep -q "^$2=" "$1" 2>/dev/null && echo yes || echo no; }
PY3="$(command -v python3)"

# ---------------------------------------------------------------- 工具目录
# RB：除 bwrap/socat/srt 外的常用命令；FB：假的 bwrap + socat + srt；OB：只有假 bwrap；NS：bwrap + socat 但没有 srt
RB="$T/rbin"; FB="$T/fbin"; OB="$T/obin"; NSB="$T/nsbin"; mkdir -p "$RB" "$FB" "$OB" "$NSB"
for c in bash sh env cat mkdir sha1sum dirname basename uname id stat readlink realpath chmod ls grep sed awk \
         tr head tail cut printf test true false rm cp mv touch date sort uniq wc xargs find python3 git; do
  p="$(command -v "$c" 2>/dev/null)"; case "$p" in /*) ln -sf "$p" "$RB/$c";; esac
done
for c in bwrap socat srt; do printf '#!/bin/sh\nexit 0\n' > "$FB/$c"; chmod +x "$FB/$c"; done
cp "$FB/bwrap" "$OB/bwrap"; cp "$FB/bwrap" "$FB/socat" "$NSB/"
DEPS="$FB:$RB"; NODEPS="$RB"; ONLYBWRAP="$OB:$RB"; NOSRT="$NSB:$RB"

# 假 claude：只用 shell 内建 + 绝对路径的 env
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
ENVX=()
# run PATH PLATFORM <harness_lib args...>   结果：$OUT/{rc,stdout,stderr,ran,argv,env}
run() {
  local path="$1" plat="$2"; shift 2
  rm -rf "$OUT"; mkdir -p "$OUT"
  env -i HOME="$HOMED" XDG_STATE_HOME="$XDG" PATH="$path" HARNESS_PLATFORM="$plat" HARNESS_CLAUDE="$FAKE" \
      ${ENVX[@]+"${ENVX[@]}"} "$PY3" "$LIB" "$@" > "$OUT/stdout" 2> "$OUT/stderr"
  echo $? > "$OUT/rc"
}
rc() { cat "$OUT/rc"; }
ran() { [ -e "$OUT/ran" ] && echo yes || echo no; }
settings_path() { awk 'p{print; exit} $0=="--settings"{p=1}' "$OUT/argv" 2>/dev/null; }
# grab NAME：把本次 strict 运行收到的配置文件复制到 $T/s-NAME.json
grab() { local sp; sp="$(settings_path)"; if [ -n "$sp" ] && [ -f "$sp" ]; then cp "$sp" "$T/s-$1.json"; else echo '<<missing>>' > "$T/s-$1.json"; fi; }

# q FILE EXPR —— 在配置 JSON 上求值 python 表达式，True→yes / False→no
cat > "$T/q.py" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["HOOKS"])
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
R = os.environ.get("R", ""); M = os.environ.get("M", "") or R; HM = os.environ.get("HOMED", "")
def ab(root, p):  # 绝对路径用 // 前缀
    return "/" + root + "/" + p
def has_path(lst, p):  # 精确或带 /** 均算
    return p in lst or p.rstrip("/") + "/**" in lst
def _fs(e):  # 配置里的路径 → 文件系统路径
    e = e[1:] if e.startswith("//") else e
    e = HM + e[1:] if e.startswith("~/") else e
    return e[:-3] if e.endswith("/**") else e
def exists_entry(e):
    return os.path.lexists(_fs(e))
def ex(root, p):  # 控制路径在 root 下是否存在
    return os.path.lexists(os.path.join(root, p[:-3] if p.endswith("/**") else p))
def cforms(p):  # 凭证路径可写成 ~/x、//<HOME>/x 或 /<HOME>/x；绝对路径可写成 //p 或 p
    if p.startswith("~/"):
        return [p, "/" + HM + p[1:], HM + p[1:]]
    return ["/" + p, p]
def cred_in(lst, p):
    return any(b in lst or b + "/**" in lst for b in cforms(p))
def cred_read(p):  # Read() 规则里单个 / 是相对配置文件，所以只认 ~/ 与 //
    return any(("Read(%s)" % b) in PD() or ("Read(%s/**)" % b) in PD() for b in cforms(p) if not b.startswith("/") or b.startswith("//"))
def in_dw(root, p):  # 沙箱路径是前缀：目录 glob 写成 X/** 或 X 均可
    return ab(root, p) in DW() or (p.endswith("/**") and ab(root, p[:-3]) in DW())
def CP():
    import harness_lib
    return list(harness_lib.CONTROL_PATHS)
CONTRACT_CP = (".claude/settings.json .claude/settings.local.json .claude/hooks/** .claude/skills/** .claude/agents/** "
               ".claude/commands/** .claude/rules/** .mcp.json CLAUDE.md scripts/** .github/** .gitattributes .gitignore "
               ".worktreeinclude .harness/verify.sh .harness/quick-check.sh .harness/allow-commands.txt .harness/locks.txt "
               ".harness/auto-decide.txt .harness/decisions.md .harness/backlog.md .harness/lib/** .harness/logs/**").split()
CREDS = ["~/.config/gh", "~/.config/git/credentials", "~/.git-credentials", "~/.ssh", "~/.gnupg", "~/.aws",
         "~/.config/gcloud", "~/.azure", "~/.kube", "~/.docker/config.json", "~/.netrc", "~/.npmrc", "~/.yarnrc.yml",
         "~/.pypirc", "~/.cargo/credentials", "~/.cargo/credentials.toml"]
DW = lambda: L("sandbox.filesystem.denyWrite")
DR = lambda: L("sandbox.filesystem.denyRead")
PD = lambda: L("permissions.deny")
AD = lambda: set(L("sandbox.network.allowedDomains"))
ND = lambda: set(L("sandbox.network.deniedDomains"))
try:
    v = eval(sys.argv[2])
except Exception as e:
    v = "ERR:" + type(e).__name__
print("yes" if v is True else "no" if v is False else v)
PY
q() { HOOKS="$HOOKS" R="${R:-}" M="${M:-}" HOMED="$HOMED" "$PY3" "$T/q.py" "$1" "$2"; }

# mkrepo NAME —— 新建 git 仓库（文件由调用者在之后写入，再 commitall）
mkrepo() { mkdir -p "$T/$1" && git -C "$T/$1" init -q -b main; }
commitall() { git -C "$T/$1" add -A && git -C "$T/$1" -c user.email=t@t -c user.name=t commit -q -m init --allow-empty; }

mkrepo node;   printf '{"name":"demo","dependencies":{"left-pad":"^1.0.0"}}\n' > "$T/node/package.json"
# 现有的控制路径（v2：沙箱 denyWrite 只列现有路径）；故意不建 CLAUDE.md / .mcp.json
( cd "$T/node" && mkdir -p src scripts .claude/hooks .harness/logs .harness/tasks .harness/gates \
  && echo x > src/a.js && echo x > scripts/a.sh && echo x > .claude/hooks/x.py && echo x > .harness/verify.sh \
  && echo x > .harness/backlog.md && echo x > .harness/logs/x.log && echo x > .harness/tasks/T-001-x.md \
  && echo x > .harness/gates/G-T001-1.md ); commitall node
mkrepo py;     printf '[project]\nname = "demo"\n' > "$T/py/pyproject.toml"; commitall py
mkrepo req;    printf 'requests==2.0\n' > "$T/req/requirements.txt"; commitall req
mkrepo go;     printf 'module example.com/demo\n\ngo 1.22\n' > "$T/go/go.mod"; commitall go
mkrepo cargo;  printf '[package]\nname = "demo"\nversion = "0.1.0"\n' > "$T/cargo/Cargo.toml"; commitall cargo
mkrepo none;   printf 'hi\n' > "$T/none/README.md"; commitall none
mkrepo ghshort; printf '{"name":"demo","dependencies":{"bar":"github:foo/bar"}}\n' > "$T/ghshort/package.json"; commitall ghshort
mkrepo gitplus; printf '{"name":"demo","dependencies":{"baz":"git+https://github.com/foo/baz.git"}}\n' > "$T/gitplus/package.json"; commitall gitplus

SECRETS=(GH_TOKEN=s1 GITHUB_TOKEN=s2 HARNESS_GH_TOKEN=s3 HARNESS_SERVE_TOKEN=s4 HARNESS_TELEGRAM_TOKEN=s5
         FOO_SECRET=s6 BAR_KEY=s7 DB_PASSWORD=s8 ANTHROPIC_API_KEY=k1 ANTHROPIC_AUTH_TOKEN=k2 CLAUDE_CODE_OAUTH_TOKEN=k3
         MY_API_KEY=k4 HARNESS_KEEP_ENV=MY_API_KEY PLAIN_VAR=p1 PLAIN_URL=https://example.com/x
         GITHUB_PAT=v1 OPENAI_APIKEY=v2 DB_PASS=v3 NPM_CONFIG__AUTHTOKEN=v4 gcp_credentials=v5 SSH_AUTH_SOCK=/tmp/agent.sock
         GIT_ASKPASS=/bin/true DOCKER_HOST=tcp://h:2375 'DATABASE_URL=postgres://u:p@h/db')

# ================================================================ A1：--settings 与配置文件
R="$T/node"
ENVX=("${SECRETS[@]}")
run "$DEPS" linux launch --strict --root "$R" -- -p hello
expect "A1: strict launch exits 0" 0 "$(rc)"
expect "A1: fake claude ran" yes "$(ran)"
expect "A1: first arg is --settings" "--settings" "$(head -1 "$OUT/argv" 2>/dev/null)"
SP="$(settings_path)"
expect "A1: settings file under \$XDG_STATE_HOME/harness/" yes "$(case "$SP" in "$XDG/harness/"*/strict-settings.json) echo yes;; *) echo no;; esac)"
expect "A1: settings dir is <repo>-<sha1[:8]>" yes "$(basename "$(dirname "$SP")" | grep -qE '^node-[0-9a-f]{8}$' && echo yes || echo no)"
expect "A1: settings file exists" yes "$([ -n "$SP" ] && [ -f "$SP" ] && echo yes || echo no)"
expect "A1: settings file mode 600" 600 "$(stat -c %a "$SP" 2>/dev/null)"
expect "A1: claude args passed through after settings" "-p|hello" "$(sed -n '3,$p' "$OUT/argv" 2>/dev/null | paste -sd'|')"
grab node; S="$T/s-node.json"; ENV_STRICT="$T/env-strict"; cp "$OUT/env" "$ENV_STRICT" 2>/dev/null || : > "$ENV_STRICT"
expect "A1: sandbox.enabled true" yes "$(q "$S" "g('sandbox.enabled') is True")"
expect "A1: sandbox.failIfUnavailable true" yes "$(q "$S" "g('sandbox.failIfUnavailable') is True")"
expect "A1: sandbox.allowUnsandboxedCommands false" yes "$(q "$S" "g('sandbox.allowUnsandboxedCommands') is False")"
expect "A1: sandbox.autoAllowBashIfSandboxed true" yes "$(q "$S" "g('sandbox.autoAllowBashIfSandboxed') is True")"
for k in sandbox.filesystem.denyRead sandbox.filesystem.denyWrite sandbox.network.allowedDomains sandbox.network.deniedDomains permissions.deny; do
  expect "A1: $k is a list" yes "$(q "$S" "isinstance(g('$k'), list)")"
done

# ================================================================ A2：环境清理
for v in GH_TOKEN GITHUB_TOKEN HARNESS_GH_TOKEN HARNESS_SERVE_TOKEN HARNESS_TELEGRAM_TOKEN FOO_SECRET BAR_KEY DB_PASSWORD \
         GITHUB_PAT OPENAI_APIKEY DB_PASS NPM_CONFIG__AUTHTOKEN gcp_credentials SSH_AUTH_SOCK GIT_ASKPASS DOCKER_HOST DATABASE_URL; do
  expect "A2: $v removed" no "$(hasenv "$ENV_STRICT" "$v")"
done
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN MY_API_KEY PLAIN_VAR PLAIN_URL PATH HOME; do
  expect "A2: $v kept" yes "$(hasenv "$ENV_STRICT" "$v")"
done
expect "A2 v2: launcher does not add HARNESS_UNATTENDED" no "$(hasenv "$ENV_STRICT" HARNESS_UNATTENDED)"
expect "A2: HARNESS_STRICT=1 set" yes "$(grep -qx 'HARNESS_STRICT=1' "$ENV_STRICT" && echo yes || echo no)"

# HARNESS_UNATTENDED=1 without --strict also means strict
ENVX=(GH_TOKEN=s1 HARNESS_UNATTENDED=1)
run "$DEPS" linux launch --root "$R" -- -p hello
expect "A2: HARNESS_UNATTENDED=1 implies strict (--settings)" "--settings" "$(head -1 "$OUT/argv" 2>/dev/null)"
expect "A2: HARNESS_UNATTENDED=1 implies env cleanup" no "$(hasenv "$OUT/env" GH_TOKEN)"
expect "A2 v2: HARNESS_UNATTENDED kept when given" yes "$(grep -qx 'HARNESS_UNATTENDED=1' "$OUT/env" && echo yes || echo no)"

# ================================================================ standard 模式（D-006）
ENVX=(GH_TOKEN=s1)
run "$NODEPS" linux launch --root "$R" -- -p hello
expect "standard: exits 0 even without bwrap/socat" 0 "$(rc)"
expect "standard: fake claude ran" yes "$(ran)"
expect "standard: args passed unchanged (no --settings)" "-p|hello" "$(paste -sd'|' "$OUT/argv" 2>/dev/null)"
expect "standard: GH_TOKEN still present" yes "$(hasenv "$OUT/env" GH_TOKEN)"
expect "standard: HARNESS_STRICT not set" no "$(hasenv "$OUT/env" HARNESS_STRICT)"

# ================================================================ --print-settings
ENVX=()
run "$DEPS" linux launch --strict --print-settings --root "$R" -- -p hello
expect "print-settings: exits 0" 0 "$(rc)"
expect "print-settings: does not run claude" no "$(ran)"
expect "print-settings: stdout is JSON with sandbox.enabled" yes "$(q "$OUT/stdout" "g('sandbox.enabled') is True")"

# ================================================================ A3：平台与依赖
ENVX=(GH_TOKEN=s1)
run "$NODEPS" linux launch --strict --root "$R" -- -p hello
expect "A3: linux without bwrap/socat exits 3" 3 "$(rc)"
expect "A3: linux missing deps -> fix mentions bubblewrap" yes "$(has "$OUT/stderr" bubblewrap)"
expect "A3: linux missing deps -> claude not run" no "$(ran)"
run "$ONLYBWRAP" linux launch --strict --root "$R" -- -p hello
expect "A3: linux without socat exits 3" 3 "$(rc)"
expect "A3: linux without socat -> claude not run" no "$(ran)"
run "$NODEPS" wsl2 launch --strict --root "$R" -- -p hello
expect "A3: wsl2 without deps exits 3" 3 "$(rc)"
expect "A3: wsl2 without deps -> claude not run" no "$(ran)"
run "$DEPS" wsl2 launch --strict --root "$R" -- -p hello
expect "A3: wsl2 with deps runs" yes "$(ran)"
for plat in linux wsl2; do
  run "$NOSRT" "$plat" launch --strict --root "$R" -- -p hello
  expect "A3 v2: $plat without srt exits 3" 3 "$(rc)"
  expect "A3 v2: $plat without srt -> fix mentions sandbox-runtime" yes "$(has "$OUT/stderr" sandbox-runtime)"
  expect "A3 v2: $plat without srt -> claude not run" no "$(ran)"
done
# v2：strict 下不是 git 仓库 → 3；选项缺值或缺 -- → 2
mkdir -p "$T/plain"
run "$DEPS" linux launch --strict --root "$T/plain" -- -p hello
expect "v2: strict in a non-git dir exits 3" 3 "$(rc)"
expect "v2: strict in a non-git dir -> claude not run" no "$(ran)"
run "$DEPS" linux launch --strict --root
expect "v2: --root without a value exits 2" 2 "$(rc)"
expect "v2: --root without a value -> claude not run" no "$(ran)"
run "$DEPS" linux launch --strict --root "$R" -p hello
expect "v2: missing -- exits 2" 2 "$(rc)"
expect "v2: missing -- -> claude not run" no "$(ran)"
for plat in wsl1 windows; do
  run "$DEPS" "$plat" launch --strict --root "$R" -- -p hello
  expect "A3: $plat refused with exit 3" 3 "$(rc)"
  expect "A3: $plat -> fix mentions WSL2" yes "$(has "$OUT/stderr" WSL2)"
  expect "A3: $plat -> claude not run" no "$(ran)"
done
run "$NODEPS" macos launch --strict --root "$R" -- -p hello
expect "A3: macos runs without bwrap/socat" 0 "$(rc)"
expect "A3: macos claude ran with --settings" "--settings" "$(head -1 "$OUT/argv" 2>/dev/null)"

# ================================================================ A4：启动点都走启动器（grep）
A4="$("$PY3" - "$SRC/scripts/harness-loop.sh" "$SRC/.claude/hooks/gate_github.py" <<'PY'
import re, sys
sh = open(sys.argv[1], encoding="utf-8").read().replace("\\\n", " ")
lines = [l for l in sh.splitlines() if not l.lstrip().startswith("#")]
direct = [l for l in lines if re.search(r'"?\$\{?CLAUDE\}?"?\s+(-p|--print)\b', l)]
print("loop_no_direct=" + ("yes" if not direct else "no"))
print("loop_uses_launcher=" + ("yes" if re.search(r'harness_lib\.py"?\s+launch\b|\bharness\s+launch\b', sh) else "no"))
# 启动行：含 launch（或 $LAUNCH 之类的变量），不是 echo
cmd = lambda l: re.search(r"launch", l, re.I) is not None and not l.lstrip().startswith("echo")
print("loop_task=" + ("yes" if any(cmd(l) and "$GOAL" in l for l in lines) else "no"))
for name, key in (("replan", "/replan"), ("groom", "/backlog-groom")):
    hit = [l for l in lines if key in l and cmd(l)]
    print(f"loop_{name}=" + ("yes" if hit else "no"))
    print(f"loop_{name}_plan=" + ("yes" if hit and all(re.search(r"--role(\s+|=)plan", l) for l in hit) else "no"))
py = open(sys.argv[2], encoding="utf-8").read()
i = py.find("def start_run")
body = py[i:py.find("\ndef ", i + 1)] if i >= 0 else ""
print("gh_launch=" + ("yes" if body and "launch" in body else "no"))
req = [l for l in py.splitlines() if "start_run(" in l and "REQ-" in l]
print("gh_req_plan=" + ("yes" if req and all(re.search(r"""role\s*=\s*["']plan["']""", l) for l in req) else "no"))
print("gh_role_passed=" + ("yes" if body and re.search(r"role\s*=\s*role", body) else "no"))
print("gh_no_direct=" + ("yes" if body and not re.search(r'\[\s*claude\s*,\s*"-p"', body) else "no"))
PY
)"
a4() { printf '%s\n' "$A4" | sed -n "s/^$1=//p"; }
expect "A4: harness-loop.sh no longer runs \"\$CLAUDE\" -p directly" yes "$(a4 loop_no_direct)"
expect "A4: harness-loop.sh invokes harness_lib.py launch" yes "$(a4 loop_uses_launcher)"
expect "A4: harness-loop.sh task run goes through launch" yes "$(a4 loop_task)"
expect "A4: harness-loop.sh replan goes through launch" yes "$(a4 loop_replan)"
expect "A4: replan launched with --role plan" yes "$(a4 loop_replan_plan)"
expect "A4: harness-loop.sh groom goes through launch" yes "$(a4 loop_groom)"
expect "A4: groom launched with --role plan" yes "$(a4 loop_groom_plan)"
expect "A4: gate_github.start_run uses the launcher" yes "$(a4 gh_launch)"
expect "A4: gate_github.start_run has no bare [claude, \"-p\"" yes "$(a4 gh_no_direct)"
expect "A4 v2: REQ intake calls start_run with role=\"plan\"" yes "$(a4 gh_req_plan)"
expect "A4 v2: start_run passes role on to the launcher" yes "$(a4 gh_role_passed)"

# ================================================================ A6：控制路径 / 凭证路径同源
expect "A6: harness_lib.CONTROL_PATHS covers the contract list" yes "$(q "$S" "set(CONTRACT_CP) <= set(CP())")"
expect "A6: every existing control path in sandbox denyWrite" yes "$(q "$S" "bool(CP()) and all(in_dw(R, p) for p in CP() if ex(R, p))")"
expect "A6 v2: existing scripts/** and .harness/verify.sh in denyWrite" yes "$(q "$S" "in_dw(R, 'scripts/**') and in_dw(R, '.harness/verify.sh')")"
expect "v2: denyWrite lists no path that does not exist" yes "$(q "$S" "s is not None and all(exists_entry(e) for e in DW())")"
expect "v2: absent CLAUDE.md / .mcp.json not in denyWrite" yes "$(q "$S" "s is not None and ab(R, 'CLAUDE.md') not in DW() and ab(R, '.mcp.json') not in DW()")"
expect "v2: absent refs/heads/master not in denyWrite" yes "$(q "$S" "s is not None and not any('refs/heads/master' in e for e in DW())")"
expect "v2: absent CLAUDE.md still has Edit/Write deny" yes "$(q "$S" "'Edit(%s)' % ab(R, 'CLAUDE.md') in PD() and 'Write(%s)' % ab(R, 'CLAUDE.md') in PD()")"
expect "A6: every control path has Edit(...) deny" yes "$(q "$S" "bool(CP()) and all('Edit(%s)' % ab(R, p) in PD() for p in CP())")"
expect "A6: every control path has Write(...) deny" yes "$(q "$S" "bool(CP()) and all('Write(%s)' % ab(R, p) in PD() for p in CP())")"
expect "A6: credential paths in denyRead" yes "$(q "$S" "all(cred_in(DR(), p) for p in CREDS)")"
expect "A6: credential paths have Read(...) deny" yes "$(q "$S" "all(cred_read(p) for p in CREDS)")"
for c in '~/.npmrc' '~/.pypirc' '~/.cargo/credentials.toml' '~/.kube' '~/.config/git/credentials'; do
  expect "A6 v2: $c in denyRead and Read() deny" yes "$(q "$S" "cred_in(DR(), '$c') and cred_read('$c')")"
done
# v2：凭证路径按实际位置解析（XDG_CONFIG_HOME / GH_CONFIG_DIR）
mkdir -p "$T/xcfg/gh" "$T/ghcfg"
ENVX=(XDG_CONFIG_HOME="$T/xcfg" GH_CONFIG_DIR="$T/ghcfg")
run "$DEPS" linux launch --strict --root "$R" -- -p hello
grab xdg; SX="$T/s-xdg.json"; ENVX=()
expect "A6 v2: \$XDG_CONFIG_HOME/gh in denyRead" yes "$(q "$SX" "cred_in(DR(), '$T/xcfg/gh')")"
expect "A6 v2: \$XDG_CONFIG_HOME/gh has Read() deny" yes "$(q "$SX" "cred_read('$T/xcfg/gh')")"
expect "A6 v2: \$GH_CONFIG_DIR in denyRead" yes "$(q "$SX" "cred_in(DR(), '$T/ghcfg')")"
expect "A6 v2: \$GH_CONFIG_DIR has Read() deny" yes "$(q "$SX" "cred_read('$T/ghcfg')")"
expect "A6: ~/.config/gh in denyRead" yes "$(q "$S" "cred_in(DR(), '~/.config/gh')")"
expect "A6: ~/.ssh has Read deny" yes "$(q "$S" "'Read(~/.ssh)' in PD() or 'Read(~/.ssh/**)' in PD()")"
expect "A6: WebFetch and WebSearch denied" yes "$(q "$S" "'WebFetch' in PD() and 'WebSearch' in PD()")"
expect "A6: main .git/hooks,config,info,refs/heads/main in denyWrite" yes \
  "$(q "$S" "all(has_path(DW(), ab(R, '.git/' + x)) for x in ('hooks', 'config', 'info', 'refs/heads/main'))")"
expect "A6 v2: allowWrite does not open the whole .git" yes "$(q "$S" "s is not None and not has_path(L('sandbox.filesystem.allowWrite'), ab(R, '.git'))")"

# --role plan：backlog.md 可写，其余控制路径仍拒绝
ENVX=()
run "$DEPS" linux launch --strict --role plan --root "$R" -- -p /backlog-groom
expect "A4/A6: --role plan launch exits 0" 0 "$(rc)"
grab plan; SPL="$T/s-plan.json"
expect "A4: --role plan omits backlog.md from denyWrite" yes "$(q "$SPL" "s is not None and ab(R, '.harness/backlog.md') not in DW()")"
expect "A4: --role plan omits Edit(backlog.md) deny" yes "$(q "$SPL" "s is not None and 'Edit(%s)' % ab(R, '.harness/backlog.md') not in PD()")"
expect "A4: --role plan keeps scripts/** in denyWrite" yes "$(q "$SPL" "in_dw(R, 'scripts/**')")"
expect "A4: --role plan keeps other control paths" yes "$(q "$SPL" "bool(CP()) and all(in_dw(R, p) for p in CP() if p != '.harness/backlog.md' and ex(R, p))")"
for e in src .git .harness/verify.sh .harness/logs; do
  expect "v2: --role plan denies existing main entry $e" yes "$(q "$SPL" "has_path(DW(), ab(R, '$e'))")"
done
for e in .harness/tasks .harness/gates .harness/backlog.md; do
  expect "v2: --role plan leaves $e writable" yes "$(q "$SPL" "s is not None and not has_path(DW(), ab(R, '$e'))")"
done
expect "A4: task role keeps backlog.md in denyWrite" yes "$(q "$S" "ab(R, '.harness/backlog.md') in DW()")"

# v2：Agent 写的 unlock 在 strict 下一律不生效（任务卡与门卡都在 worktree 里，Claude 自己能写）
mkrepo unl; printf '{"name":"demo"}\n' > "$T/unl/package.json"; commitall unl
git -C "$T/unl" worktree add -q "$T/unl-wt" -b task/T-123-x 2>/dev/null
WU="$T/unl-wt"; mkdir -p "$WU/.harness/tasks" "$WU/.harness/gates" "$WU/scripts"; echo x > "$WU/scripts/foo.sh"; echo x > "$WU/.harness/verify.sh"
printf -- '---\nid: T-123\ntitle: x\nstatus: in_progress\nunlock: [scripts/**, .harness/verify.sh]\n---\n\n# T-123 x\n' > "$WU/.harness/tasks/T-123-x.md"
printf -- '---\nid: G-T123-1\ntask: T-123\nkind: unlock\nstatus: approved\n---\n\n# G-T123-1 解锁\n' > "$WU/.harness/gates/G-T123-1.md"
R="$WU"; M="$T/unl"
run "$DEPS" linux launch --strict --task T-123 --root "$R" -- -p hello
expect "v2: --task launch in worktree exits 0" 0 "$(rc)"
SPU="$(settings_path)"; grab unl; SU="$T/s-unl.json"
expect "v2: settings file named strict-settings-task-T-123.json" strict-settings-task-T-123.json "$(basename "${SPU:-none}")"
expect "v2: no leftover temp files beside the settings" "" "$(ls -A "$(dirname "${SPU:-$T/none/x}")" 2>/dev/null | grep -vE '^strict-settings(-[a-z]+-[A-Za-z0-9-]+)?\.json$')"
expect "v2: agent-written unlock ignored: scripts/** stays in denyWrite" yes "$(q "$SU" "in_dw(R, 'scripts/**')")"
expect "v2: agent-written unlock ignored: verify.sh stays in denyWrite" yes "$(q "$SU" "in_dw(R, '.harness/verify.sh')")"
expect "v2: agent-written unlock ignored: Edit/Write denies kept" yes \
  "$(q "$SU" "all(('%s(%s)' % (k, ab(R, p))) in PD() for k in ('Edit', 'Write') for p in ('scripts/**', '.harness/verify.sh'))")"
# v2：.git 白名单写入
expect "v2: allowWrite has main .git/objects" yes "$(q "$SU" "has_path(L('sandbox.filesystem.allowWrite'), ab(M, '.git/objects'))")"
expect "v2: allowWrite has main .git/refs/heads/task" yes "$(q "$SU" "has_path(L('sandbox.filesystem.allowWrite'), ab(M, '.git/refs/heads/task'))")"
expect "v2: allowWrite has main .git/worktrees/<name>" yes "$(q "$SU" "has_path(L('sandbox.filesystem.allowWrite'), ab(M, '.git/worktrees/unl-wt'))")"
expect "v2: allowWrite does not contain main .git itself" yes "$(q "$SU" "s is not None and not has_path(L('sandbox.filesystem.allowWrite'), ab(M, '.git'))")"
expect "v2: worktree launch denies main .git/hooks and .git/config" yes "$(q "$SU" "has_path(DW(), ab(M, '.git/hooks')) and has_path(DW(), ab(M, '.git/config'))")"
M=""

# worktree：工作目录与主仓库各一份；配置目录按主仓库命名
mkrepo wtmain; printf '{"name":"demo"}\n' > "$T/wtmain/package.json"; commitall wtmain
git -C "$T/wtmain" worktree add -q "$T/wt-feat" -b feat 2>/dev/null
R="$T/wt-feat"; M="$T/wtmain"
run "$DEPS" linux launch --strict --root "$R" -- -p hello
grab wt; SW="$T/s-wt.json"
expect "A6: worktree settings dir named after main repo" yes "$(basename "$(dirname "$(settings_path)")" | grep -qE '^wtmain-[0-9a-f]{8}$' && echo yes || echo no)"
expect "A6: worktree control paths denied in worktree" yes "$(q "$SW" "bool(CP()) and all(in_dw(R, p) for p in CP() if ex(R, p))")"
expect "A6: worktree control paths denied in main repo too" yes "$(q "$SW" "bool(CP()) and all(in_dw(M, p) for p in CP() if ex(M, p))")"
expect "A6: worktree main .git/hooks denied" yes "$(q "$SW" "has_path(DW(), ab(M, '.git/hooks'))")"
M=""

# ================================================================ A5：按技术栈的网络白名单
for name in node py req go cargo none ghshort gitplus; do
  R="$T/$name"
  run "$DEPS" linux launch --strict --root "$R" -- -p hello
  grab "net-$name"
done
NS() { echo "$T/s-net-$1.json"; }
expect "A5: node -> npm registries" yes "$(q "$(NS node)" "{'registry.npmjs.org', 'registry.yarnpkg.com'} <= AD()")"
expect "A5: pyproject -> pypi" yes "$(q "$(NS py)" "{'pypi.org', 'files.pythonhosted.org'} <= AD()")"
expect "A5: requirements.txt -> pypi" yes "$(q "$(NS req)" "{'pypi.org', 'files.pythonhosted.org'} <= AD()")"
expect "A5: go -> golang proxy" yes "$(q "$(NS go)" "{'proxy.golang.org', 'sum.golang.org'} <= AD()")"
expect "A5: cargo -> crates.io" yes "$(q "$(NS cargo)" "{'crates.io', 'index.crates.io', 'static.crates.io'} <= AD()")"
expect "A5: no stack -> empty allowedDomains" yes "$(q "$(NS none)" "g('sandbox.network.allowedDomains') == []")"
expect "A5: node does not get pypi" yes "$(q "$(NS node)" "s is not None and 'pypi.org' not in AD()")"
for name in node py req go cargo none; do
  expect "A5: $name has no github.com" yes "$(q "$(NS "$name")" "s is not None and not ({'github.com', 'codeload.github.com'} & AD())")"
done
expect "A5: github: dependency adds github.com" yes "$(q "$(NS ghshort)" "{'github.com', 'codeload.github.com'} <= AD()")"
expect "A5: git+https dependency adds github.com" yes "$(q "$(NS gitplus)" "{'github.com', 'codeload.github.com'} <= AD()")"
for name in node py req go cargo none ghshort gitplus; do
  expect "A5: $name deniedDomains has telegram/webhook.site/pastebin" yes \
    "$(q "$(NS "$name")" "{'api.telegram.org', 'webhook.site', 'pastebin.com'} <= ND()")"
done

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
