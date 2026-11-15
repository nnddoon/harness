#!/usr/bin/env bash
# T-023 验收（0.2.2 热修，审查 R-1）：verify 经由 npm/npx/pnpm/yarn/bun 到达的 JS 测试运行器，
# 其配置文件与 script 里直接调用的仓库文件都算验证入口：verify_entry_paths / control-diff / strict denyWrite / doctor。
# 按任务卡 T-023「接口约定」。control-diff 读基准提交的 package.json，不读任务分支的。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
TOP="$(cd "$SRC/.." && pwd)"
LIB="$SRC/.claude/hooks/harness_lib.py"
HOOKS="$SRC/.claude/hooks"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-t023.XXXXXX")"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
PY3="$(command -v python3)"
OUT="$T/out"
HOMED="$T/home"; XDG="$T/state"; mkdir -p "$HOMED" "$XDG"
FAKECRON="$T/fake-crontab"; printf '#!/bin/sh\nexit 1\n' > "$FAKECRON"; chmod +x "$FAKECRON"

NPMSET=".npmrc|.pnpmfile.cjs|.yarnrc|.yarnrc.yml|package.json"
# 保守分支要出现的代表 glob（接口约定 JS_ALL）
JSALL="jest.config.* vitest.config.* vitest.workspace.* vite.config.* .mocharc* playwright.config.* karma.conf.* cypress.config.* ava.config.* .nycrc* .c8rc* babel.config.* .babelrc*"

# ---------------------------------------------------------------- 工具
mkd() { mkdir -p "$T/$1/.harness"; }
verify() { mkd "$1"; printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/$1/.harness/verify.sh"; }
# pkg DIR SCRIPTS_JSON [SUBDIR]  —— 写 DIR[/SUBDIR]/package.json，scripts 用给定 JSON 对象
pkg() { local d="$T/$1${3:+/$3}"; mkdir -p "$d"; printf '{"name":"demo","scripts":%s}\n' "$2" > "$d/package.json"; }
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
# vhas DIR ENTRY... —— 每个 ENTRY 都在 → yes
vhas() { local d="$1" l; shift; l="$(vep "$T/$d" | tr '|' '\n')"; for e in "$@"; do printf '%s\n' "$l" | grep -qxF -- "$e" || { echo no; return; }; done; echo yes; }
# vnone DIR ENTRY... —— 一个都不在 → yes（输出异常也算 no）
vnone() { local d="$1" l; shift; l="$(vep "$T/$d")"; case "$l" in EXC:*|BAD:*) echo no; return;; esac
  for e in "$@"; do printf '%s\n' "$l" | tr '|' '\n' | grep -qxF -- "$e" && { echo no; return; }; done; echo yes; }
jsall() { vhas "$1" $JSALL; }
jsnone() { vnone "$1" $JSALL; }
rc() { cat "$OUT/rc"; }
lines() { paste -sd'|' "$OUT/stdout" 2>/dev/null; }

# ================================================================ A1：verify_entry_paths —— 运行器识别
pkg j1 '{"test":"jest"}'; verify j1 'set -e
npm run test'
expect "A1 jest via npm run test: jest.config.* + babel + package.json" yes "$(vhas j1 'jest.config.*' 'babel.config.*' '.babelrc*' package.json)"
expect "A1 jest: resolved precisely (no mocha / vite / playwright globs)" yes "$(vnone j1 '.mocharc*' 'vite.config.*' 'playwright.config.*')"
expect "A1 jest: output still sorted+unique list" yes "$(case "$(vep "$T/j1")" in EXC:*|BAD:*) echo no;; *) echo yes;; esac)"
pkg vt '{"test":"vitest run"}'; verify vt 'npm test'
expect "A1 vitest via npm test: vitest.config.* vitest.workspace.* vite.config.* + babel" yes "$(vhas vt 'vitest.config.*' 'vitest.workspace.*' 'vite.config.*' 'babel.config.*')"
expect "A1 vitest: no jest.config.*" yes "$(vnone vt 'jest.config.*')"
pkg mo '{"test":"mocha"}'; verify mo 'yarn test'
expect "A1 mocha via yarn test: .mocharc*" yes "$(vhas mo '.mocharc*' '.babelrc*')"
pkg pw '{"e2e":"playwright test"}'; verify pw 'pnpm run e2e'
expect "A1 playwright via pnpm run e2e: playwright.config.*" yes "$(vhas pw 'playwright.config.*' 'babel.config.*')"
pkg ka '{"test":"karma start --single-run"}'; verify ka 'npm t'
expect "A1 karma via npm t: karma.conf.*" yes "$(vhas ka 'karma.conf.*')"
pkg cy '{"cy":"cypress run"}'; verify cy 'npm run-script cy'
expect "A1 cypress via npm run-script cy: cypress.config.*" yes "$(vhas cy 'cypress.config.*')"
pkg av '{"test":"ava"}'; verify av 'bun run test'
expect "A1 ava via bun run test: ava.config.* + bunfig.toml" yes "$(vhas av 'ava.config.*' bunfig.toml)"
pkg ny '{"test":"nyc mocha"}'; verify ny 'yarn run test'
expect "A1 nyc wraps mocha: .nycrc* and .mocharc*" yes "$(vhas ny '.nycrc*' '.mocharc*')"
pkg c8 '{"test":"c8 vitest run"}'; verify c8 'pnpm test'
expect "A1 c8 wraps vitest: .c8rc* and vitest.config.*" yes "$(vhas c8 '.c8rc*' 'vitest.config.*')"
pkg ce '{"test":"cross-env NODE_ENV=test jest --ci"}'; verify ce 'npm test'
expect "A1 cross-env NODE_ENV=test jest: jest.config.*" yes "$(vhas ce 'jest.config.*')"
pkg yb '{"lint":"eslint ."}'; verify yb 'yarn jest --ci'
expect "A1 yarn <runner> (not a script): jest.config.*" yes "$(vhas yb 'jest.config.*')"
mkd bt; printf '{"name":"b"}\n' > "$T/bt/package.json"; verify bt 'bun test'
expect "A1 bun test: bunfig.toml" yes "$(vhas bt bunfig.toml)"

# ================================================================ A2：npx / exec 直接调用运行器（verify.sh 里）
verify nx 'npx --yes playwright test'
expect "A2 npx --yes playwright test (no package.json): playwright.config.* + babel" yes "$(vhas nx 'playwright.config.*' 'babel.config.*')"
expect "A2 npx playwright: npm entry set still there" yes "$(vhas nx package.json .npmrc)"
expect "A2 npx playwright: precise (no jest.config.*)" yes "$(vnone nx 'jest.config.*')"
verify px 'pnpm exec vitest run'
expect "A2 pnpm exec vitest: vitest.config.*" yes "$(vhas px 'vitest.config.*' 'vite.config.*')"
verify bx 'bunx ava'
expect "A2 bunx ava: ava.config.*" yes "$(vhas bx 'ava.config.*')"
verify ne 'npm exec -- mocha'
expect "A2 npm exec -- mocha: .mocharc*" yes "$(vhas ne '.mocharc*')"
verify yd 'yarn dlx jest'
expect "A2 yarn dlx jest: jest.config.*" yes "$(vhas yd 'jest.config.*')"

# ================================================================ A3：script 里的文件参数
pkg cf '{"test":"jest --config cfg/jest.ci.js"}'; verify cf 'npm test'
expect "A3 jest --config cfg/jest.ci.js: path locked" yes "$(vhas cf cfg/jest.ci.js 'jest.config.*')"
pkg ce2 '{"test":"mocha --config=cfg/mocharc.yml"}'; verify ce2 'npm test'
expect "A3 mocha --config=cfg/mocharc.yml (any extension): path locked" yes "$(vhas ce2 cfg/mocharc.yml)"
pkg cc '{"test":"vitest run -c cfg/vt.config.mts"}'; verify cc 'npm test'
expect "A3 vitest -c cfg/vt.config.mts: path locked" yes "$(vhas cc cfg/vt.config.mts)"
pkg cyf '{"test":"cypress run --config-file cy/ci.cfg"}'; verify cyf 'npm test'
expect "A3 cypress --config-file cy/ci.cfg: path locked" yes "$(vhas cyf cy/ci.cfg)"
pkg nd '{"test":"node scripts/run-tests.js"}'; verify nd 'npm test'
expect "A3 node scripts/run-tests.js: path locked" yes "$(vhas nd scripts/run-tests.js)"
pkg nd2 '{"test":"node --trace-warnings tools/run.mjs --fast"}'; verify nd2 'npm test'
expect "A3 node [opts] tools/run.mjs: path locked" yes "$(vhas nd2 tools/run.mjs)"
pkg sh1 '{"test":"bash tools/t.sh && ./tools/u.sh"}'; verify sh1 'npm test'
expect "A3 bash tools/t.sh && ./tools/u.sh: both locked" yes "$(vhas sh1 tools/t.sh tools/u.sh)"
pkg fl '{"test":"jest -r ./test/setup.cjs test/unit/ \"src/**/*.test.js\""}'; verify fl 'npm test'
expect "A3 repo-file-looking token (./test/setup.cjs) locked" yes "$(vhas fl test/setup.cjs)"
expect "A3 directory and glob tokens NOT locked" yes "$(vnone fl test/unit/ test/unit 'src/**/*.test.js')"
pkg ne2 '{"test":"node -e \"process.exit(0)\""}'; verify ne2 'npm test'
expect "A3 node -e CODE: the code is not a path" yes "$(vnone ne2 'process.exit(0)' '"process.exit(0)"')"
verify vn 'node tools/check.js'
expect "A3 verify.sh: node tools/check.js locked directly" yes "$(vhas vn tools/check.js)"

# ================================================================ A4：嵌套 npm run、pre/post 钩子、深度、环
pkg ns '{"test":"npm run lint && npm run unit","lint":"eslint .","unit":"vitest run"}'; verify ns 'npm test'
expect "A4 nested npm run unit -> vitest.config.*" yes "$(vhas ns 'vitest.config.*')"
expect "A4 nested: something found -> not conservative (no jest.config.*)" yes "$(vnone ns 'jest.config.*' '.mocharc*')"
pkg ny2 '{"test":"yarn unit","unit":"pnpm run inner","inner":"mocha"}'; verify ny2 'npm test'
expect "A4 nested yarn/pnpm script calls -> .mocharc*" yes "$(vhas ny2 '.mocharc*')"
pkg hk '{"pretest":"node tools/gen.js","test":"jest","posttest":"c8 report"}'; verify hk 'npm test'
expect "A4 pretest/posttest hooks: tools/gen.js, .c8rc*, jest.config.*" yes "$(vhas hk tools/gen.js '.c8rc*' 'jest.config.*')"
expect "A4 hooks: precise (no .mocharc*)" yes "$(vnone hk '.mocharc*')"
pkg hk2 '{"preunit":"node tools/prep.js","unit":"jest","postunit":"node tools/after.js"}'; verify hk2 'npm run unit'
expect "A4 preX/postX for npm run X" yes "$(vhas hk2 tools/prep.js tools/after.js)"
pkg d3 '{"test":"npm run a","a":"npm run b","b":"npm run c","c":"jest"}'; verify d3 'npm test'
expect "A4 depth 3 still resolved: jest.config.*" yes "$(vhas d3 'jest.config.*')"
expect "A4 depth 3: precise (no .mocharc*)" yes "$(vnone d3 '.mocharc*')"
pkg d4 '{"test":"npm run a","a":"npm run b","b":"npm run c","c":"npm run d","d":"jest"}'; verify d4 'npm test'
expect "A4 depth 4 > 3 -> conservative (all JS globs)" yes "$(jsall d4)"
pkg cyc '{"test":"npm run a","a":"npm run test"}'; verify cyc 'npm test'
expect "A4 script cycle: terminates, no exception" yes "$(case "$(vep "$T/cyc")" in EXC:*|BAD:*|"") echo no;; *) echo yes;; esac)"
expect "A4 script cycle with no runner -> conservative" yes "$(jsall cyc)"

# ================================================================ A5：保守分支
mkd bad; printf '{"scripts": {"test": "jest"' > "$T/bad/package.json"; verify bad 'npm test'
expect "A5 invalid package.json -> all JS globs + babel" yes "$(jsall bad)"
mkd arr; printf '[]\n' > "$T/arr/package.json"; verify arr 'npm test'
expect "A5 package.json not an object -> all JS globs" yes "$(jsall arr)"
mkd sno; printf '{"name":"x","scripts":"jest"}\n' > "$T/sno/package.json"; verify sno 'npm test'
expect "A5 scripts not an object -> all JS globs" yes "$(jsall sno)"
pkg ms '{"lint":"eslint ."}'; verify ms 'npm run nope'
expect "A5 script missing -> all JS globs" yes "$(jsall ms)"
mkd nos; printf '{"name":"demo"}\n' > "$T/nos/package.json"; verify nos 'npm run test'
expect "A5 no scripts key, npm run test -> all JS globs" yes "$(jsall nos)"
pkg ech '{"test":"echo ok"}'; verify ech 'npm test'
expect "A5 script with no recognizable runner/file -> all JS globs" yes "$(jsall ech)"
verify tsc 'npx tsc --noEmit'
expect "A5 npx <unknown binary> -> all JS globs" yes "$(jsall tsc)"
pkg ci '{"test":"jest"}'; verify ci 'npm ci && npm test'
expect "A5 npm ci (no script) does not trigger conservative" yes "$(vnone ci '.mocharc*' 'vitest.config.*')"
verify nopkg 'npm run test'
expect "A5 package.json absent -> exactly the npm entry set (T-018 unchanged)" "$NPMSET" "$(vep "$T/nopkg")"

# ================================================================ A6：目录
pkg wb '{"test":"jest"}' web; verify wb 'cd web && npm test'
expect "A6 cd web && npm test: web/jest.config.* + web/babel.config.*" yes "$(vhas wb 'web/jest.config.*' 'web/babel.config.*' web/package.json)"
expect "A6 cd web: no root jest.config.*" yes "$(vnone wb 'jest.config.*')"
pkg pf '{"test":"vitest run"}' app; verify pf 'npm --prefix app run test'
expect "A6 npm --prefix app run test: app/vitest.config.*" yes "$(vhas pf 'app/vitest.config.*')"
expect "A6 --prefix: no root vitest.config.*" yes "$(vnone pf 'vitest.config.*')"
pkg pc '{"test":"jest"}' svc; verify pc 'pnpm -C svc test'
expect "A6 pnpm -C svc test: svc/jest.config.*" yes "$(vhas pc 'svc/jest.config.*')"
pkg sc '{"e2e":"cd e2e && playwright test"}'; verify sc 'npm run e2e'
expect "A6 cd inside script: e2e/playwright.config.*" yes "$(vhas sc 'e2e/playwright.config.*')"
pkg fw '{"test":"node tools/r.js"}' web; verify fw 'cd web && npm test'
expect "A6 file path relative to package dir: web/tools/r.js" yes "$(vhas fw web/tools/r.js)"

# ================================================================ A7：没有误报（只有 Python 的 verify.sh）
pkg py '{"test":"jest"}'; verify py 'set -e
python3 -m pytest -q tests/
echo "jest mocha vitest playwright are not used here"
ruff check .'
expect "A7 python-only verify: no JS runner globs" yes "$(jsnone py)"
expect "A7 python-only verify: no package.json / bunfig.toml" yes "$(vnone py package.json bunfig.toml)"
expect "A7 python-only verify: python entries still there" yes "$(vhas py pyproject.toml conftest.py)"

# ================================================================ A8：control-diff（git 仓库）
mkrepo() { mkdir -p "$T/$1" && git -C "$T/$1" init -q -b main && git -C "$T/$1" config user.email t@t && git -C "$T/$1" config user.name t; }
br() { local name="$1"; shift; git checkout -q -b "$name" main && eval "$*" && git add -A && git commit -qm "$name" && git checkout -q -f main; }
cdl() {  # cdl <root> <args…> → $OUT/{rc,stdout}
  local r="$1"; shift
  rm -rf "$OUT"; mkdir -p "$OUT"
  ( cd "$T" && env -i HOME="$HOMED" PATH="$PATH" XDG_STATE_HOME="$XDG" "$PY3" "$LIB" control-diff "$@" --root "$r" ) > "$OUT/stdout" 2> "$OUT/stderr"
  echo $? > "$OUT/rc"
}

# R-1 复现脚本（审查原文，docs/feedback/s003-review-r1.md）
cat > "$T/probe_ctl.py" <<'PY'
import json, subprocess, sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]).resolve()))
import harness_lib as H
G = ["git", "-c", "user.name=t", "-c", "user.email=t@t"]
d = Path(tempfile.mkdtemp(dir=sys.argv[2]))
run = lambda *a: subprocess.run(list(a), cwd=d, check=True, capture_output=True, text=True)
run("git", "init", "-q", "-b", "main")
(d / ".harness").mkdir()
(d / ".harness" / "verify.sh").write_text("#!/usr/bin/env bash\nset -e\nnpm run test\n")
(d / "package.json").write_text(json.dumps({"scripts": {"test": "jest"}}))
(d / "jest.config.js").write_text("module.exports = {}\n")
run(*G, "add", "-A"); run(*G, "commit", "-qm", "init")
for f, body in (("jest.config.js", "module.exports = { testMatch: [], passWithNoTests: true }\n"),
                ("package.json", json.dumps({"scripts": {"test": "jest --passWithNoTests"}}))):
    br = "t-" + f.replace(".", "-")
    run("git", "checkout", "-q", "-b", br, "main")
    (d / f).write_text(body)
    run(*G, "commit", "-qam", "weaken")
    print(f, "->", H.control_diff(d, "main", br) or "none (would merge)")
    run("git", "checkout", "-q", "main")
PY
PROBE="$(cd "$T" && "$PY3" -I "$T/probe_ctl.py" "$HOOKS" "$T" 2>&1)"
expect "A8 R-1 repro: jest.config.js-only branch hit" "jest.config.js -> ['jest.config.js']" "$(printf '%s\n' "$PROBE" | grep '^jest.config.js' | head -1)"
expect "A8 R-1 repro: package.json branch still hit" "package.json -> ['package.json']" "$(printf '%s\n' "$PROBE" | grep '^package.json' | head -1)"

# jest 仓库：配置 / babel / 文件参数 / 钩子
mkrepo cj; cd "$T/cj" || exit 1
mkdir -p .harness src tools cfg; echo a > src/a.js
printf '#!/usr/bin/env bash\nset -e\nnpm run test\n' > .harness/verify.sh
printf '{"name":"cj","scripts":{"pretest":"node tools/gen.js","test":"jest --config cfg/jest.ci.js && npm run unit","unit":"mocha"}}\n' > package.json
printf 'module.exports = {}\n' > jest.config.js; printf 'module.exports = {}\n' > cfg/jest.ci.js; echo 'x' > tools/gen.js
git add -A && git commit -qm init
br k-jest   'printf "module.exports = { testMatch: [], passWithNoTests: true }\n" > jest.config.js'
br k-cfg    'printf "module.exports = { testMatch: [] }\n" > cfg/jest.ci.js'
br k-babel  'printf "{\"plugins\":[\"x\"]}\n" > .babelrc'
br k-mocha  'printf "spec: []\n" > .mocharc.yml'
br k-hook   'echo "process.exit(0)" > tools/gen.js'
br k-src    'echo b >> src/a.js'
# 分支改 scripts 指向新文件：package.json 本身命中，入口按基准版本（jest）判定，分支 package.json 推出的 cfg/m.yml 不算
br k-retarget 'printf "{\"name\":\"cj\",\"scripts\":{\"test\":\"mocha --config cfg/m.yml\"}}\n" > package.json; printf "spec: []\n" > cfg/m.yml; printf "module.exports = { testMatch: [] }\n" > jest.config.js'
cd "$T"
for c in "k-jest jest.config.js" "k-cfg cfg/jest.ci.js" "k-babel .babelrc" "k-mocha .mocharc.yml" "k-hook tools/gen.js"; do
  set -- $c
  cdl "$T/cj" main "$1"
  expect "A8 control-diff $1: exit 1, lists exactly $2" "1 $2" "$(rc) $(lines)"
done
cdl "$T/cj" main k-src
expect "A8 control-diff src-only: exit 0" "0 " "$(rc) $(lines)"
cdl "$T/cj" main k-retarget
expect "A8 base-vs-branch: package.json + base-derived jest.config.js hit; branch-only cfg/m.yml not used" "1 jest.config.js|package.json" "$(rc) $(lines)"

# vitest / mocha / playwright 同类：只改配置的分支命中
for c in "rv vitest vite.config.ts" "rv2 vitest vitest.workspace.ts" "rm mocha .mocharc.json" "rp playwright playwright.config.ts"; do
  set -- $c
  mkrepo "$1"; cd "$T/$1" || exit 1
  mkdir -p .harness; printf '#!/usr/bin/env bash\nnpm test\n' > .harness/verify.sh
  printf '{"name":"x","scripts":{"test":"%s"}}\n' "$2" > package.json; echo '{}' > "$3"
  git add -A && git commit -qm init
  br w "echo '// weaken' >> $3"
  cd "$T"
  cdl "$T/$1" main w
  expect "A8 control-diff $2: config-only branch ($3) hit" "1 $3" "$(rc) $(lines)"
done

# 保守：基准 package.json 坏了 → 新建任何运行器配置都命中
mkrepo rb; cd "$T/rb" || exit 1
mkdir -p .harness; printf '#!/usr/bin/env bash\nnpm test\n' > .harness/verify.sh; printf '{"scripts": {' > package.json
git add -A && git commit -qm init
br w 'printf "spec: []\n" > .mocharc.yml'
cd "$T"
cdl "$T/rb" main w
expect "A8 conservative (invalid base package.json): new .mocharc.yml hit" "1 .mocharc.yml" "$(rc) $(lines)"
# npx 直接在 verify.sh：没有 package.json
mkrepo rx; cd "$T/rx" || exit 1
mkdir -p .harness; printf '#!/usr/bin/env bash\nnpx playwright test\n' > .harness/verify.sh; echo '{}' > playwright.config.ts
git add -A && git commit -qm init
br w 'echo "// weaken" >> playwright.config.ts'
cd "$T"
cdl "$T/rx" main w
expect "A8 npx playwright in verify.sh: playwright.config.ts hit" "1 playwright.config.ts" "$(rc) $(lines)"
# 嵌套 + 子目录
mkrepo rn; cd "$T/rn" || exit 1
mkdir -p .harness web; printf '#!/usr/bin/env bash\ncd web && npm test\n' > .harness/verify.sh
printf '{"name":"w","scripts":{"test":"npm run unit","unit":"vitest run"}}\n' > web/package.json; echo '{}' > web/vitest.config.ts
git add -A && git commit -qm init
br w 'echo "// weaken" >> web/vitest.config.ts'
br w2 'echo "// fine" > vitest.config.ts'
cd "$T"
cdl "$T/rn" main w
expect "A8 nested npm run in web/: web/vitest.config.ts hit" "1 web/vitest.config.ts" "$(rc) $(lines)"
cdl "$T/rn" main w2
expect "A8 web/ runner: root vitest.config.ts is not an entry" "0 " "$(rc) $(lines)"
# 只有 Python：jest.config.js 不是控制路径
mkrepo rpy; cd "$T/rpy" || exit 1
mkdir -p .harness; printf '#!/usr/bin/env bash\npython3 -m pytest -q\n' > .harness/verify.sh
printf '{"name":"p","scripts":{"test":"jest"}}\n' > package.json; echo '{}' > jest.config.js
git add -A && git commit -qm init
br w 'echo "// x" >> jest.config.js'
cd "$T"
cdl "$T/rpy" main w
expect "A8 python-only verify: jest.config.js edit not a control hit" "0 " "$(rc) $(lines)"

# ================================================================ A9：strict denyWrite / Edit-Write deny（jest 仓库）
mkrepo sj; cd "$T/sj" || exit 1
mkdir -p .harness; printf '#!/usr/bin/env bash\nnpm run test\n' > .harness/verify.sh
printf '{"name":"sj","scripts":{"test":"jest"}}\n' > package.json
echo '{}' > jest.config.js; echo '{}' > babel.config.js; echo 'spec: []' > .mocharc.yml
git add -A && git commit -qm init
cd "$T"
rm -rf "$OUT"; mkdir -p "$OUT"
env -i HOME="$HOMED" XDG_STATE_HOME="$XDG" PATH="$PATH" HARNESS_PLATFORM=linux \
  "$PY3" "$LIB" launch --strict --print-settings --root "$T/sj" -- -p x > "$OUT/settings.json" 2> "$OUT/stderr"
sq() { R="$T/sj" "$PY3" - "$OUT/settings.json" "$1" <<'PY'
import json, os, sys
try:
    s = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("no-settings"); sys.exit()
R = os.environ["R"]
dw = s["sandbox"]["filesystem"]["denyWrite"]; pd = s["permissions"]["deny"]
ab = lambda p: "/" + R + "/" + p
in_dw = lambda p: ab(p) in dw
ew = lambda p: ("Edit(%s)" % ab(p)) in pd and ("Write(%s)" % ab(p)) in pd
print("yes" if eval(sys.argv[2]) else "no")
PY
}
expect "A9 strict jest: jest.config.js in sandbox denyWrite" yes "$(sq "in_dw('jest.config.js')")"
expect "A9 strict jest: babel.config.js in sandbox denyWrite" yes "$(sq "in_dw('babel.config.js')")"
expect "A9 strict jest: Edit/Write(jest.config.*) denied" yes "$(sq "ew('jest.config.*')")"
expect "A9 strict jest: Edit/Write(.babelrc*) denied" yes "$(sq "ew('.babelrc*')")"
expect "A9 strict jest: package.json still in denyWrite" yes "$(sq "in_dw('package.json')")"
expect "A9 strict jest: unrelated .mocharc.yml not in denyWrite (resolved precisely)" yes "$(sq "not in_dw('.mocharc.yml')")"
expect "A9 strict jest: no placeholder files created for absent globs" no "$([ -e "$T/sj/.babelrc" ] || [ -e "$T/sj/.babelrc*" ] && echo yes || echo no)"

# ================================================================ A10：doctor 显示验证入口文件
doctor() {  # doctor REPO → $OUT/doc
  rm -rf "$OUT"; mkdir -p "$OUT"
  (cd "$1" && env -i HOME="$HOMED" XDG_STATE_HOME="$XDG" PATH="$PATH" HARNESS_PLATFORM=linux HARNESS_CRONTAB="$FAKECRON" \
     HARNESS_GATE_CHANNEL=off "$PY3" "$SRC/bin/harness" doctor --repo "$1") > "$OUT/doc" 2> "$OUT/doc.err"
  echo $? > "$OUT/rc"
}
sec() { awk -v h="## $2" '$0==h{p=1;next} /^## /{p=0} p' "$1" 2>/dev/null | sed '/^[[:space:]]*$/d'; }
doctor "$T/sj"
expect "A10 doctor jest repo: exit 0" 0 "$(rc)"
expect "A10 doctor jest repo: has '## 验证入口文件' section" 1 "$(grep -cx '## 验证入口文件' "$OUT/doc")"
expect "A10 doctor: section lists jest.config.*" yes "$(sec "$OUT/doc" 验证入口文件 | grep -qxF 'jest.config.*' && echo yes || echo no)"
expect "A10 doctor: section lists package.json" yes "$(sec "$OUT/doc" 验证入口文件 | grep -qxF 'package.json' && echo yes || echo no)"
expect "A10 doctor: known runners only -> still no '## 验证入口' (unknown-runner) section" 0 "$(grep -cx '## 验证入口' "$OUT/doc")"
mkrepo dpy; mkdir -p "$T/dpy/.harness"; printf '#!/usr/bin/env bash\npython3 -m pytest -q\n' > "$T/dpy/.harness/verify.sh"
printf '{"name":"p","scripts":{"test":"jest"}}\n' > "$T/dpy/package.json"; git -C "$T/dpy" add -A; git -C "$T/dpy" commit -qm init
doctor "$T/dpy"
expect "A10 doctor python-only: section present with pyproject.toml" yes "$(sec "$OUT/doc" 验证入口文件 | grep -qxF 'pyproject.toml' && echo yes || echo no)"
expect "A10 doctor python-only: no jest.config.*" no "$(sec "$OUT/doc" 验证入口文件 | grep -qxF 'jest.config.*' && echo yes || echo no)"
mkrepo dnone; mkdir -p "$T/dnone/.harness"; printf '#!/usr/bin/env bash\nexit 0\n' > "$T/dnone/.harness/verify.sh"; git -C "$T/dnone" add -A; git -C "$T/dnone" commit -qm init
doctor "$T/dnone"
expect "A10 doctor no entries: no '## 验证入口文件' section" 0 "$(grep -cx '## 验证入口文件' "$OUT/doc")"

# ================================================================ A11：0.2.2 发版
pv() { "$PY3" -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$1" 2>/dev/null || echo none; }
expect "A11 pkg/plugin/VERSION = 0.2.2" 0.2.2 "$(tr -d '[:space:]' < "$SRC/plugin/VERSION")"
expect "A11 plugins/harness plugin.json version = 0.2.2" 0.2.2 "$(pv "$TOP/plugins/harness/.claude-plugin/plugin.json")"
expect "A11 RELEASED.json version = 0.2.2" 0.2.2 "$(pv "$SRC/plugin/RELEASED.json")"
expect "A11 plugin rebuilt: hooks/harness_lib.py matches pkg" yes "$(cmp -s "$TOP/plugins/harness/hooks/harness_lib.py" "$LIB" && echo yes || echo no)"
expect "A11 plugin rebuilt: cli/doctor_cmd.py matches pkg" yes "$(cmp -s "$TOP/plugins/harness/cli/doctor_cmd.py" "$SRC/cli/doctor_cmd.py" && echo yes || echo no)"
expect "A11 README has a '### 0.2.2' entry" 1 "$(grep -cx '### 0.2.2' "$SRC/README.md")"
expect "A11 README 0.2.2 entry mentions jest.config" yes "$(awk '$0=="### 0.2.2"{p=1;next} /^### /{p=0} p' "$SRC/README.md" | grep -qF 'jest.config' && echo yes || echo no)"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
