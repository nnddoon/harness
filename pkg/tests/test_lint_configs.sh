#!/usr/bin/env bash
# T-025 验收（0.2.2，项目文档 R-1-hotfix-scope.md）：Python 与 Vue 的 lint / 类型检查 / 覆盖率配置算验证入口。
# 按任务卡 T-025「接口约定」。三组技术栈（Vue create-vue、pytest+ruff+mypy、uv/make）里文档表的每个「未锁」文件：
# 任务分支只改它 → control_diff 命中（不带 task，不牵涉 T-024 范围检查），strict denyWrite 有它；
# 对照组（源码 / 测试文件 / lock 文件）不命中；uv run / poetry run / python -m 等前缀剥离后识别。
set -u
set -f   # 入口 glob（mypy/**、tsconfig*.json）当字面参数传，不做路径展开
SRC="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$SRC/.claude/hooks/harness_lib.py"
HOOKS="$SRC/.claude/hooks"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-t025.XXXXXX")"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
PY3="$(command -v python3)"
OUT="$T/out"
HOMED="$T/home"; XDG="$T/state"; mkdir -p "$HOMED" "$XDG"

LOCKS="uv.lock poetry.lock Pipfile.lock pdm.lock package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock bun.lockb bun.lock"

# ---------------------------------------------------------------- 工具
mkd() { mkdir -p "$T/$1/.harness"; }
verify() { mkd "$1"; printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/$1/.harness/verify.sh"; }
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
# vhas DIR ENTRY... —— 每个 ENTRY（字面的路径 / glob）都在 → yes
vhas() { local d="$1" l; shift; l="$(vep "$T/$d" | tr '|' '\n')"; for e in "$@"; do printf '%s\n' "$l" | grep -qxF -- "$e" || { echo no; return; }; done; echo yes; }
# vnone DIR ENTRY... —— 一个都不在 → yes（异常算 no）
vnone() { local d="$1" l; shift; l="$(vep "$T/$d")"; case "$l" in EXC:*|BAD:*) echo no; return;; esac
  for e in "$@"; do printf '%s\n' "$l" | tr '|' '\n' | grep -qxF -- "$e" && { echo no; return; }; done; echo yes; }
# vmatch DIR PATH... —— 每个具体文件都被某个入口 glob 匹配 → yes
vmatch() { HOOKS="$HOOKS" "$PY3" - "$T/$1" "${@:2}" <<'PY' 2>&1
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["HOOKS"])
import harness_lib as H
try:
    e = H.verify_entry_paths(Path(sys.argv[1]))
    print("yes" if all(H.matches_any(p, e) for p in sys.argv[2:]) else "no")
except Exception as x:
    print("EXC:" + type(x).__name__)
PY
}
# vnomatch DIR PATH... —— 没有一个具体文件被入口匹配 → yes
vnomatch() { HOOKS="$HOOKS" "$PY3" - "$T/$1" "${@:2}" <<'PY' 2>&1
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["HOOKS"])
import harness_lib as H
try:
    e = H.verify_entry_paths(Path(sys.argv[1]))
    print("yes" if not any(H.matches_any(p, e) for p in sys.argv[2:]) else "no")
except Exception as x:
    print("EXC:" + type(x).__name__)
PY
}
mkrepo() { mkdir -p "$T/$1" && git -C "$T/$1" init -q -b main && git -C "$T/$1" config user.email t@t && git -C "$T/$1" config user.name t; }
commitall() { git -C "$T/$1" add -A && git -C "$T/$1" commit -qm init; }
# brch REPO NAME FILE —— 从 main 开分支，只改 FILE（追加一行），提交，回到 main
brch() { ( cd "$T/$1" && git checkout -q -b "$2" main && printf '\n# weaken\n' >> "$3" && git add -A && git commit -qm "$2" && git checkout -q -f main ); }
# ctl REPO BRANCH —— 进程内 control_diff(root, "main", BRANCH)，不带 task
ctl() { HOOKS="$HOOKS" "$PY3" -c 'import os,sys; sys.path.insert(0,os.environ["HOOKS"]); import harness_lib as H
try: print("|".join(H.control_diff(sys.argv[1], "main", sys.argv[2])))
except BaseException as e: print("EXC:"+type(e).__name__)' "$T/$1" "$2" 2>&1 | tail -1; }
# strict REPO → $T/s-REPO.json
strict() {
  env -i HOME="$HOMED" XDG_STATE_HOME="$XDG" PATH="$PATH" HARNESS_PLATFORM=linux \
    "$PY3" "$LIB" launch --strict --print-settings --root "$T/$1" -- -p x > "$T/s-$1.json" 2> "$T/s-$1.err"
}
# in_dw REPO FILE → yes/no（FILE 的绝对路径在 sandbox denyWrite 里）
in_dw() { R="$T/$1" "$PY3" - "$T/s-$1.json" "$2" <<'PY'
import json, os, sys
try:
    s = json.load(open(sys.argv[1], encoding="utf-8"))
    dw = s["sandbox"]["filesystem"]["denyWrite"]
except Exception:
    print("no-settings"); sys.exit()
print("yes" if "/" + os.environ["R"] + "/" + sys.argv[2] in dw else "no")
PY
}
# stack_case REPO FILES… —— 每个文件：只改它的分支 control_diff 命中、strict denyWrite 有它
hit_all() { local r="$1" f; shift
  for f in "$@"; do
    brch "$r" "w-$(printf '%s' "$f" | tr '/.' '--')" "$f"
    expect "$r: branch changing only $f -> control_diff hit" "$f" "$(ctl "$r" "w-$(printf '%s' "$f" | tr '/.' '--')")"
    expect "$r: strict denyWrite has $f" yes "$(in_dw "$r" "$f")"
  done
}
miss_all() { local r="$1" f; shift
  for f in "$@"; do
    brch "$r" "c-$(printf '%s' "$f" | tr '/.' '--')" "$f"
    expect "$r: branch changing only $f -> no control_diff hit" "" "$(ctl "$r" "c-$(printf '%s' "$f" | tr '/.' '--')")"
    expect "$r: strict denyWrite does not have $f" no "$(in_dw "$r" "$f")"
  done
}

# ================================================================ 组 1：Vue（create-vue 脚手架）
VUE_SCRIPTS='{"dev":"vite","build":"vite build","preview":"vite preview","test:unit":"vitest","test:e2e":"playwright test","type-check":"vue-tsc --build","lint":"eslint . --fix","format":"prettier --write src/"}'
VUE_VERIFY='set -e
npm run lint && npm run type-check && npm run test:unit -- --run && npm run build'
VUE_UNLOCKED="vite.config.ts vitest.config.ts playwright.config.ts tsconfig.json tsconfig.app.json tsconfig.vitest.json eslint.config.js .prettierrc.json"
mkrepo vue; pkg vue "$VUE_SCRIPTS"; verify vue "$VUE_VERIFY"
for f in $VUE_UNLOCKED; do echo '{}' > "$T/vue/$f"; done
mkdir -p "$T/vue/src" "$T/vue/src/__tests__"; echo '<template/>' > "$T/vue/src/App.vue"; echo 'x' > "$T/vue/src/__tests__/App.spec.ts"
echo '{"lockfileVersion":3}' > "$T/vue/package-lock.json"
commitall vue
expect "V entries: vite.config.* vitest.config.* playwright.config.* tsconfig*.json eslint.config.* .prettierrc*" yes \
  "$(vhas vue 'vite.config.*' 'vitest.config.*' 'playwright.config.*' 'tsconfig*.json' 'eslint.config.*' '.prettierrc*')"
expect "V entries cover every 未锁 file (glob match)" yes "$(vmatch vue $VUE_UNLOCKED)"
expect "V entries: package-lock.json / src/App.vue not matched" yes "$(vnomatch vue package-lock.json src/App.vue src/__tests__/App.spec.ts)"
strict vue
expect "V strict --print-settings: exit ok, no traceback" 0 "$(grep -c Traceback "$T/s-vue.err")"
hit_all vue $VUE_UNLOCKED
miss_all vue src/App.vue src/__tests__/App.spec.ts package-lock.json
expect "V package.json itself still a hit" "package.json" "$(brch vue w-pkg package.json; ctl vue w-pkg)"

# create-vue 的真实 build：run-p 不认识 → 保守，tsconfig / vite 配置仍在
pkg vrp '{"build":"run-p type-check \"build-only {@}\" --","type-check":"vue-tsc --build","build-only":"vite build"}'; verify vrp 'npm run build'
expect "V run-p build (create-vue): tsconfig*.json and vite.config.* still entries" yes "$(vhas vrp 'tsconfig*.json' 'vite.config.*')"

# ================================================================ J：JS 工具表（同一次调用识别到 vitest → 精确，不保守）
pkg jt '{"test":"vitest run && eslint . && prettier --check . && vue-tsc --noEmit && stylelint \"src/**/*.css\" && vite build"}'; verify jt 'npm test'
expect "J eslint -> eslint.config.* .eslintrc* .eslintignore" yes "$(vhas jt 'eslint.config.*' '.eslintrc*' '.eslintignore')"
expect "J prettier -> .prettierrc* prettier.config.* .prettierignore" yes "$(vhas jt '.prettierrc*' 'prettier.config.*' '.prettierignore')"
expect "J vue-tsc -> tsconfig*.json" yes "$(vhas jt 'tsconfig*.json')"
expect "J stylelint -> .stylelintrc* stylelint.config.*" yes "$(vhas jt '.stylelintrc*' 'stylelint.config.*')"
expect "J vite -> vite.config.*" yes "$(vhas jt 'vite.config.*')"
expect "J tools beside vitest: precise (no jest.config.* / .mocharc* / playwright.config.*)" yes "$(vnone jt 'jest.config.*' '.mocharc*' 'playwright.config.*')"
expect "J tsconfig glob covers tsconfig.app.json / tsconfig.vitest.json / tsconfig.node.json" yes "$(vmatch jt tsconfig.json tsconfig.app.json tsconfig.vitest.json tsconfig.node.json)"
pkg jtsc '{"test":"jest && tsc --noEmit"}'; verify jtsc 'npm test'
expect "J tsc -> tsconfig*.json" yes "$(vhas jtsc 'tsconfig*.json')"
pkg jbin '{"test":"vitest run && node_modules/.bin/eslint . && cross-env NODE_ENV=ci prettier -c ."}'; verify jbin 'npm test'
expect "J node_modules/.bin/eslint and cross-env prettier recognised" yes "$(vhas jbin 'eslint.config.*' '.prettierrc*')"
pkg jig '{"test":"vitest run && eslint --ignore-path cfg/lint-ignore ."}'; verify jig 'npm test'
expect "J --ignore-path value locked" yes "$(vhas jig cfg/lint-ignore)"
# 只跑 lint / 类型检查 / 构建工具：不算识别到运行器 → 保守 JS_ALL
pkg jlo '{"lint":"eslint ."}'; verify jlo 'npm run lint'
expect "J eslint-only script -> eslint globs + conservative JS_ALL (jest.config.*, playwright.config.*)" yes "$(vhas jlo 'eslint.config.*' 'jest.config.*' 'playwright.config.*')"
pkg jto '{"type-check":"vue-tsc --build"}'; verify jto 'npm run type-check'
expect "J vue-tsc-only script -> tsconfig*.json + conservative (.prettierrc*, vitest.config.*)" yes "$(vhas jto 'tsconfig*.json' '.prettierrc*' 'vitest.config.*')"
# verify 层直接调用
mkd jd1; echo '{"name":"x"}' > "$T/jd1/package.json"; verify jd1 'npx eslint .'
expect "J verify: npx eslint . -> eslint.config.*" yes "$(vhas jd1 'eslint.config.*')"
mkd jd2; echo '{"name":"x"}' > "$T/jd2/package.json"; verify jd2 './node_modules/.bin/vue-tsc --build'
expect "J verify: ./node_modules/.bin/vue-tsc -> tsconfig*.json + package.json" yes "$(vhas jd2 'tsconfig*.json' package.json)"
mkd jd3; verify jd3 'env CI=1 prettier --check .'
expect "J verify: env CI=1 prettier -> .prettierrc*" yes "$(vhas jd3 '.prettierrc*')"
mkd jd4; verify jd4 'stylelint "src/**/*.css"'
expect "J verify: stylelint -> .stylelintrc*" yes "$(vhas jd4 '.stylelintrc*' 'stylelint.config.*')"
mkd jd5; verify jd5 'cd web && tsc -p tsconfig.build.json'
expect "J verify: cd web && tsc -> web/tsconfig*.json + web/tsconfig.build.json" yes "$(vhas jd5 'web/tsconfig*.json' web/tsconfig.build.json)"
pkg jy '{"test":"vitest run"}'; verify jy 'yarn eslint . && pnpm vue-tsc --noEmit'
expect "J yarn eslint / pnpm vue-tsc (not scripts) -> eslint.config.* tsconfig*.json" yes "$(vhas jy 'eslint.config.*' 'tsconfig*.json')"
mkd jecho; verify jecho 'echo "eslint prettier tsc vue-tsc vite stylelint"'
expect "J echo of tool names is not a call -> []" "" "$(vep "$T/jecho")"
# JS_ALL 扩充：保守分支 / workspace
mkd jbad; printf '{"scripts": {' > "$T/jbad/package.json"; verify jbad 'npm test'
expect "J conservative (bad package.json) now includes tool globs" yes \
  "$(vhas jbad 'tsconfig*.json' 'eslint.config.*' '.eslintrc*' '.prettierrc*' 'prettier.config.*' '.stylelintrc*' 'stylelint.config.*' 'vite.config.*')"
pkg jws '{"test":"jest"}'; verify jws 'pnpm -r test'
expect "J workspace selector: **/tsconfig*.json and **/eslint.config.*" yes "$(vhas jws '**/tsconfig*.json' '**/eslint.config.*' '**/.prettierrc*')"
# 不误报：只有 Python 的 verify
mkd jpy; echo '{"name":"x","scripts":{"lint":"eslint ."}}' > "$T/jpy/package.json"; verify jpy 'pytest -q'
expect "J python-only verify: no JS tool globs" yes "$(vnone jpy 'tsconfig*.json' 'eslint.config.*' '.prettierrc*' 'vite.config.*')"

# ================================================================ 组 2：Python（pytest + ruff + mypy）
PY_UNLOCKED="mypy.ini ruff.toml .flake8 .coveragerc"
mkrepo pyr; verify pyr 'set -e
ruff check . && mypy src && pytest -q'
printf '[project]\nname = "demo"\n' > "$T/pyr/pyproject.toml"
printf '[mypy]\nstrict = True\n' > "$T/pyr/mypy.ini"; printf 'line-length = 100\n' > "$T/pyr/ruff.toml"
printf '[flake8]\nmax-line-length = 100\n' > "$T/pyr/.flake8"; printf '[run]\nbranch = True\n' > "$T/pyr/.coveragerc"
mkdir -p "$T/pyr/src" "$T/pyr/tests"; echo 'x = 1' > "$T/pyr/src/app.py"; echo 'def test_x(): pass' > "$T/pyr/tests/test_app.py"
echo 'version = 1' > "$T/pyr/uv.lock"
commitall pyr
expect "P entries: mypy.ini ruff.toml .flake8 .coveragerc" yes "$(vhas pyr mypy.ini ruff.toml .flake8 .coveragerc)"
expect "P entries: existing pyproject.toml / conftest.py kept" yes "$(vhas pyr pyproject.toml conftest.py pytest.ini setup.cfg tox.ini)"
expect "P entries: src/app.py tests/test_app.py uv.lock not matched" yes "$(vnomatch pyr src/app.py tests/test_app.py uv.lock)"
strict pyr
hit_all pyr $PY_UNLOCKED
miss_all pyr src/app.py tests/test_app.py uv.lock
expect "P pyproject.toml still a hit" "pyproject.toml" "$(brch pyr w-pp pyproject.toml; ctl pyr w-pp)"

# 每个工具精确（不连带别的工具）
for c in "pr1|ruff check .|ruff.toml .ruff.toml pyproject.toml|mypy.ini .flake8 .coveragerc" \
         "pr2|mypy src|mypy.ini .mypy.ini pyproject.toml setup.cfg|ruff.toml .flake8" \
         "pr3|dmypy run -- src|mypy.ini .mypy.ini|ruff.toml" \
         "pr4|flake8 src|.flake8 setup.cfg tox.ini|mypy.ini ruff.toml" \
         "pr5|pylint src|.pylintrc pylintrc pyproject.toml|mypy.ini ruff.toml" \
         "pr6|coverage report --fail-under=90|.coveragerc pyproject.toml|mypy.ini ruff.toml" \
         "pr7|black --check .|pyproject.toml|ruff.toml mypy.ini" \
         "pr8|isort --check-only .|.isort.cfg pyproject.toml|ruff.toml mypy.ini"; do
  IFS='|' read -r d cmd want nope <<EOF
$c
EOF
  mkd "$d"; verify "$d" "$cmd"
  expect "P $cmd -> $want" yes "$(vhas "$d" $want)"
  expect "P $cmd: precise (no $nope)" yes "$(vnone "$d" $nope)"
done
# pytest / tox / nox → PY_ALL（插件经 addopts 读这些配置）
for c in "pa1|pytest -q" "pa2|pytest --cov=src --cov-report=term" "pa3|tox -e lint" "pa4|nox -s tests" "pa5|py.test tests"; do
  IFS='|' read -r d cmd <<EOF
$c
EOF
  mkd "$d"; verify "$d" "$cmd"
  expect "P $cmd -> PY_ALL (.coveragerc ruff.toml mypy.ini .flake8 .pylintrc)" yes "$(vhas "$d" .coveragerc ruff.toml mypy.ini .flake8 .pylintrc)"
done
# 命令词：路径 / env / VAR= / cd；echo 不算
mkd pw1; verify pw1 '.venv/bin/ruff check .'
expect "P .venv/bin/ruff -> ruff.toml" yes "$(vhas pw1 ruff.toml)"
mkd pw2; verify pw2 'env PYTHONPATH=src mypy src'
expect "P env PYTHONPATH=src mypy -> mypy.ini" yes "$(vhas pw2 mypy.ini)"
mkd pw3; verify pw3 'MYPY_FORCE_COLOR=1 mypy src'
expect "P VAR=x mypy -> mypy.ini" yes "$(vhas pw3 mypy.ini)"
mkd pw4; verify pw4 'cd api && ruff check .'
expect "P cd api && ruff -> api/ruff.toml (not root)" yesyes "$(vhas pw4 api/ruff.toml)$(vnone pw4 ruff.toml)"
mkd pw5; verify pw5 'echo "ruff mypy flake8 pylint coverage"'
expect "P echo of tool names is not a call -> []" "" "$(vep "$T/pw5")"
# 配置路径参数
mkd pc1; verify pc1 'mypy --config-file ci/mypy.ini src'
expect "P mypy --config-file ci/mypy.ini -> locked" yes "$(vhas pc1 ci/mypy.ini)"
mkd pc2; verify pc2 'ruff check --config ci/ruff.toml .'
expect "P ruff --config ci/ruff.toml -> locked" yes "$(vhas pc2 ci/ruff.toml)"
mkd pc3; verify pc3 'pylint --rcfile=ci/pylintrc src'
expect "P pylint --rcfile=ci/pylintrc -> locked" yes "$(vhas pc3 ci/pylintrc)"
mkd pc4; verify pc4 'pytest --cov=src --cov-config=ci/cov.cfg'
expect "P pytest --cov-config=ci/cov.cfg -> locked" yes "$(vhas pc4 ci/cov.cfg)"

# ================================================================ 前缀剥离
# 已知工具：剥前缀后精确识别（不走保守 PY_ALL）
for c in "x1|uv run mypy src|mypy.ini pyproject.toml|ruff.toml .flake8" \
         "x2|uv run --frozen mypy src|mypy.ini|ruff.toml" \
         "x3|uv run --extra dev --frozen ruff check .|ruff.toml .ruff.toml|mypy.ini" \
         "x4|uv run --with types-requests -- mypy src|mypy.ini|ruff.toml" \
         "x5|poetry run mypy src|mypy.ini|ruff.toml" \
         "x6|pipenv run flake8 src|.flake8 Pipfile|mypy.ini" \
         "x7|hatch run ruff check .|ruff.toml hatch.toml|mypy.ini" \
         "x8|hatch run lint:ruff check .|ruff.toml|mypy.ini" \
         "x9|pdm run mypy src|mypy.ini pyproject.toml|ruff.toml" \
         "x10|python -m mypy src|mypy.ini mypy.py mypy/**|ruff.toml" \
         "x11|python3 -m ruff check .|ruff.toml|mypy.ini" \
         "x12|python3.12 -W error -m flake8 src|.flake8|ruff.toml" \
         "x13|uv run python -m mypy src|mypy.ini|ruff.toml" \
         "x14|poetry run python -m ruff check .|ruff.toml|mypy.ini"; do
  IFS='|' read -r d cmd want nope <<EOF
$c
EOF
  mkd "$d"; verify "$d" "$cmd"
  expect "X $cmd -> $want" yes "$(vhas "$d" $want)"
  expect "X $cmd: precise (no $nope)" yes "$(vnone "$d" $nope)"
done
# 前缀 + pytest → PY_ALL
for c in "y1|uv run pytest -q" "y2|poetry run pytest" "y3|uv run --frozen python -m pytest -q" "y4|pdm run pytest" \
         "y5|coverage run -m pytest -q" "y6|python -m coverage run -m pytest" "y7|hatch run test:pytest"; do
  IFS='|' read -r d cmd <<EOF
$c
EOF
  mkd "$d"; verify "$d" "$cmd"
  expect "X $cmd -> PY_ALL incl. .coveragerc ruff.toml mypy.ini" yes "$(vhas "$d" .coveragerc ruff.toml mypy.ini pyproject.toml)"
done
# 前缀 + 不认识的 X → 保守 PY_ALL
mkd z1; verify z1 'pipenv run test'
expect "X pipenv run <script> -> Pipfile + PY_ALL" yes "$(vhas z1 Pipfile ruff.toml mypy.ini .coveragerc)"
mkd z2; verify z2 'hatch run lint:all'
expect "X hatch run <env:script> -> hatch.toml + PY_ALL" yes "$(vhas z2 hatch.toml ruff.toml mypy.ini)"
mkd z3; verify z3 'uv run ./tools/check'
expect "X uv run ./tools/check -> PY_ALL" yes "$(vhas z3 ruff.toml mypy.ini .flake8)"
# --directory
mkd z4; verify z4 'uv run --directory api ruff check .'
expect "X uv run --directory api ruff -> api/ruff.toml" yes "$(vhas z4 api/ruff.toml api/pyproject.toml)"
# Python 工具在 package.json script 里
pkg zp '{"lint":"ruff check . && mypy src","test":"uv run pytest -q"}'; verify zp 'npm run lint && npm test'
expect "X package.json scripts: ruff / mypy / uv run pytest -> ruff.toml mypy.ini .coveragerc" yes "$(vhas zp ruff.toml mypy.ini .coveragerc)"
# make 不变
mkd mk; verify mk 'make lint'
expect "M make-only verify: exactly the make set (unchanged)" "GNUmakefile|Makefile|makefile" "$(vep "$T/mk")"

# ================================================================ 组 3：Python（uv / make）
mkrepo uvm; verify uvm 'set -e
uv run pytest -q && make lint'
printf '[project]\nname = "demo"\n' > "$T/uvm/pyproject.toml"; printf 'lint:\n\tuv run ruff check .\n' > "$T/uvm/Makefile"
printf 'line-length = 100\n' > "$T/uvm/ruff.toml"; echo 'version = 1' > "$T/uvm/uv.lock"
mkdir -p "$T/uvm/src" "$T/uvm/tests"; echo 'x = 1' > "$T/uvm/src/app.py"; echo 'def test_x(): pass' > "$T/uvm/tests/test_app.py"
commitall uvm
expect "U entries: ruff.toml + pyproject.toml + Makefile" yes "$(vhas uvm ruff.toml pyproject.toml Makefile)"
expect "U entries: uv.lock not an entry" yes "$(vnomatch uvm uv.lock)"
strict uvm
hit_all uvm ruff.toml
miss_all uvm uv.lock src/app.py tests/test_app.py
expect "U Makefile still a hit" "Makefile" "$(brch uvm w-mk Makefile; ctl uvm w-mk)"
# CLI control-diff（不带 --task）同样命中
( cd "$T" && env -i HOME="$HOMED" PATH="$PATH" XDG_STATE_HOME="$XDG" "$PY3" "$LIB" control-diff main w-ruff-toml --root "$T/uvm" ) > "$T/cli.out" 2>&1; CRC=$?
expect "U CLI control-diff ruff.toml-only branch: exit 1, lists ruff.toml" "1 ruff.toml" "$CRC $(paste -sd'|' "$T/cli.out")"

# ================================================================ L：lock 文件不是入口（全栈 verify）
mkd lk; pkg lk '{"lint":"eslint .","test":"vitest run","build":"vite build"}'
verify lk 'npm run lint && npm test && npm run build
pnpm test && yarn test && bun run test
uv run pytest -q && poetry run mypy src && pipenv run flake8 && pdm run ruff check . && hatch run pytest'
expect "L no lock file matched by any entry (npm/pnpm/yarn/bun/uv/poetry/pipenv/pdm)" yes "$(vnomatch lk $LOCKS)"
expect "L lock names not listed literally" yes "$(vnone lk $LOCKS)"
expect "L sanity: the same verify does lock tsconfig / ruff / mypy configs" yes "$(vmatch lk tsconfig.app.json ruff.toml mypy.ini eslint.config.js)"

# ================================================================ v2（第 2 轮审查：层叠配置、一次性运行器前缀、pre-commit）
# brnew REPO NAME FILE —— 从 main 开分支，新建 / 改 FILE（目录不存在就建），提交，回到 main
brnew() { ( cd "$T/$1" && git checkout -q -b "$2" main && mkdir -p "$(dirname "$3")" && printf '\n# weaken\n' >> "$3" && git add -A && git commit -qm "$2" && git checkout -q -f main ); }
bn() { printf 'n-%s' "$1" | tr '/.' '--'; }
# new_hit REPO FILE... —— 只新建 / 改 FILE 的分支 control_diff 命中
new_hit() { local r="$1" f; shift
  for f in "$@"; do brnew "$r" "$(bn "$f")" "$f"
    expect "v2 $r: branch adding only $f -> control_diff hit" "$f" "$(ctl "$r" "$(bn "$f")")"; done; }
new_miss() { local r="$1" f; shift
  for f in "$@"; do brnew "$r" "$(bn "$f")" "$f"
    expect "v2 $r: branch changing only $f -> no control_diff hit" "" "$(ctl "$r" "$(bn "$f")")"; done; }

# ---- D1：ruff 按文件就近取配置
mkd r1; verify r1 'ruff check .'
expect "v2 D1 ruff -> **/ruff.toml **/.ruff.toml **/pyproject.toml" yes "$(vhas r1 '**/ruff.toml' '**/.ruff.toml' '**/pyproject.toml')"
expect "v2 D1 ruff: root literals kept (ruff.toml .ruff.toml pyproject.toml)" yes "$(vhas r1 ruff.toml .ruff.toml pyproject.toml)"
expect "v2 D1 ruff: nested configs matched" yes "$(vmatch r1 src/ruff.toml src/.ruff.toml src/pyproject.toml pkg/sub/ruff.toml)"
mkd r2; verify r2 'cd api && uv run ruff check .'
expect "v2 D1 cd api && uv run ruff -> api/**/ruff.toml api/**/pyproject.toml" yes "$(vhas r2 'api/**/ruff.toml' 'api/**/pyproject.toml')"
mkd r3; verify r3 'mypy src'
expect "v2 D1 mypy does not cascade: no **/ruff.toml / **/pyproject.toml" yes "$(vnone r3 '**/ruff.toml' '**/pyproject.toml')"
mkd r4; verify r4 'pytest -q'
expect "v2 D1 pytest (PY_ALL) carries **/ruff.toml **/pyproject.toml" yes "$(vhas r4 '**/ruff.toml' '**/.ruff.toml' '**/pyproject.toml')"
mkd r5; verify r5 'uvx ruff check .'
expect "v2 D1 uvx ruff -> **/ruff.toml" yes "$(vhas r5 '**/ruff.toml')"
# control-diff / strict：pytest + ruff + mypy 仓库
mkrepo pyr2; verify pyr2 'set -e
ruff check . && mypy src && pytest -q'
printf '[project]\nname = "demo"\n' > "$T/pyr2/pyproject.toml"; printf 'line-length = 100\n' > "$T/pyr2/ruff.toml"
mkdir -p "$T/pyr2/src" "$T/pyr2/tests" "$T/pyr2/lib"; echo 'x = 1' > "$T/pyr2/src/app.py"; echo 'def test_x(): pass' > "$T/pyr2/tests/test_app.py"
printf '[tool.ruff]\nexclude = []\n' > "$T/pyr2/lib/pyproject.toml"; printf 'extend = "../ruff.toml"\n' > "$T/pyr2/lib/ruff.toml"
echo 'version = 1' > "$T/pyr2/uv.lock"; echo 'x' > "$T/pyr2/poetry.lock"
commitall pyr2
new_hit pyr2 src/ruff.toml src/.ruff.toml src/pyproject.toml tests/pyproject.toml lib/ruff.toml lib/pyproject.toml
new_miss pyr2 src/app.py tests/test_app.py uv.lock poetry.lock src/helpers.py
strict pyr2
expect "v2 D1 strict: existing lib/ruff.toml in denyWrite" yes "$(in_dw pyr2 lib/ruff.toml)"
expect "v2 D1 strict: existing lib/pyproject.toml in denyWrite" yes "$(in_dw pyr2 lib/pyproject.toml)"
expect "v2 D1 strict: src/app.py / uv.lock not in denyWrite" "no no" "$(in_dw pyr2 src/app.py) $(in_dw pyr2 uv.lock)"
# uv / make 仓库：ruff 只在 Makefile 配方里，经 pytest 的 PY_ALL 锁住
mkrepo uvm2; verify uvm2 'set -e
uv run pytest -q && make lint'
printf '[project]\nname = "demo"\n' > "$T/uvm2/pyproject.toml"; printf 'lint:\n\tuv run ruff check .\n' > "$T/uvm2/Makefile"
mkdir -p "$T/uvm2/src" "$T/uvm2/tests"; echo 'x = 1' > "$T/uvm2/src/app.py"; echo 'def test_x(): pass' > "$T/uvm2/tests/test_app.py"
echo 'version = 1' > "$T/uvm2/uv.lock"; commitall uvm2
new_hit uvm2 src/ruff.toml src/pyproject.toml
new_miss uvm2 uv.lock src/app.py tests/test_app.py

# ---- D1b：eslint / prettier / stylelint 层叠配置
pkg c1 '{"test":"vitest run && eslint . && prettier --check . && stylelint \"src/**/*.css\""}'; verify c1 'npm test'
expect "v2 D1b eslint -> **/eslint.config.* **/.eslintrc* **/.eslintignore" yes "$(vhas c1 '**/eslint.config.*' '**/.eslintrc*' '**/.eslintignore')"
expect "v2 D1b prettier -> **/.prettierrc* **/prettier.config.* **/.prettierignore" yes "$(vhas c1 '**/.prettierrc*' '**/prettier.config.*' '**/.prettierignore')"
expect "v2 D1b prettier -> .editorconfig **/.editorconfig" yes "$(vhas c1 .editorconfig '**/.editorconfig')"
expect "v2 D1b stylelint -> **/.stylelintrc* **/stylelint.config.*" yes "$(vhas c1 '**/.stylelintrc*' '**/stylelint.config.*')"
expect "v2 D1b config keys in nested package.json -> **/package.json" yes "$(vhas c1 '**/package.json')"
expect "v2 D1b root literals kept" yes "$(vhas c1 'eslint.config.*' '.eslintrc*' '.prettierrc*' '.stylelintrc*')"
expect "v2 D1b still precise beside vitest (no jest.config.* / .mocharc*)" yes "$(vnone c1 'jest.config.*' '.mocharc*' '**/jest.config.*')"
pkg c2 '{"test":"vitest run && vue-tsc --noEmit && vite build"}'; verify c2 'npm test'
expect "v2 D1b tsc / vite not cascaded: no **/tsconfig*.json **/vite.config.* **/package.json" yes "$(vnone c2 '**/tsconfig*.json' '**/vite.config.*' '**/package.json')"
mkd c3; verify c3 'cd web && npx prettier --check src/'
expect "v2 D1b cd web && npx prettier -> web/**/.prettierrc* web/.editorconfig" yes "$(vhas c3 'web/**/.prettierrc*' web/.editorconfig 'web/**/.editorconfig')"
pkg c4 '{"lint":"eslint ."}'; verify c4 'npm run lint'
expect "v2 D1b conservative JS_ALL carries **/ tool globs" yes "$(vhas c4 '**/.prettierrc*' '**/.stylelintrc*' '**/eslint.config.*')"
# control-diff / strict：create-vue 仓库 + prettier 检查
mkrepo vue2; pkg vue2 "$VUE_SCRIPTS"; verify vue2 "$VUE_VERIFY
npx prettier --check src/"
for f in vite.config.ts vitest.config.ts tsconfig.json tsconfig.app.json eslint.config.js .prettierrc.json; do echo '{}' > "$T/vue2/$f"; done
mkdir -p "$T/vue2/src/components" "$T/vue2/src/legacy"; echo '<template/>' > "$T/vue2/src/App.vue"; echo '<template/>' > "$T/vue2/src/components/Hello.vue"
echo '{"root":false}' > "$T/vue2/src/legacy/.eslintrc.json"; echo '{}' > "$T/vue2/src/legacy/.prettierrc"
echo '{"lockfileVersion":3}' > "$T/vue2/package-lock.json"
commitall vue2
new_hit vue2 src/.prettierrc.json src/components/.prettierrc src/prettier.config.js src/.prettierignore .editorconfig src/.editorconfig \
  src/eslint.config.js src/.eslintrc.json src/.eslintignore src/.stylelintrc.json src/package.json
new_miss vue2 src/App.vue src/components/Hello.vue src/main.ts package-lock.json
strict vue2
expect "v2 D1b strict: existing src/legacy/.eslintrc.json in denyWrite" yes "$(in_dw vue2 src/legacy/.eslintrc.json)"
expect "v2 D1b strict: existing src/legacy/.prettierrc in denyWrite" yes "$(in_dw vue2 src/legacy/.prettierrc)"
expect "v2 D1b strict: src/App.vue / package-lock.json not in denyWrite" "no no" "$(in_dw vue2 src/App.vue) $(in_dw vue2 package-lock.json)"

# ---- D2：uvx / uv tool run / pipx run
for c in "u1|uvx ruff check .|ruff.toml pyproject.toml|mypy.ini" \
         "u2|uv tool run mypy src|mypy.ini pyproject.toml|ruff.toml" \
         "u3|pipx run flake8 src|.flake8 pyproject.toml|mypy.ini" \
         "u4|uvx ruff@0.6.0 check .|ruff.toml|mypy.ini" \
         "u5|uvx --from ruff==0.6.0 ruff check .|ruff.toml|mypy.ini" \
         "u6|pipx run --spec flake8==7.0 flake8 src|.flake8|mypy.ini" \
         "u7|uvx --python 3.12 --with types-requests mypy src|mypy.ini|ruff.toml" \
         "u8|uv tool run --from pylint pylint src|.pylintrc|ruff.toml"; do
  IFS='|' read -r d cmd want nope <<EOF
$c
EOF
  mkd "$d"; verify "$d" "$cmd"
  expect "v2 D2 $cmd -> $want" yes "$(vhas "$d" $want)"
  expect "v2 D2 $cmd: precise (no $nope)" yes "$(vnone "$d" $nope)"
done
mkd u9; verify u9 'uvx some-unknown-tool --check'
expect "v2 D2 uvx <unknown> -> PY_ALL" yes "$(vhas u9 pyproject.toml ruff.toml mypy.ini .coveragerc)"
mkd u10; verify u10 'pipx run pytest -q'
expect "v2 D2 pipx run pytest -> PY_ALL" yes "$(vhas u10 .coveragerc ruff.toml mypy.ini)"

# ---- D3：pre-commit
PCSET=".pre-commit-config.yaml .pre-commit-config.yml .pre-commit-hooks.yaml"
for c in "k1|pre-commit run --all-files" "k2|uv run pre-commit run -a" "k3|python -m pre_commit run --all-files" \
         "k4|uvx pre-commit run --all-files" "k5|SKIP=mypy pre-commit run --all-files --show-diff-on-failure"; do
  IFS='|' read -r d cmd <<EOF
$c
EOF
  mkd "$d"; verify "$d" "$cmd"
  expect "v2 D3 $cmd -> pre-commit config files" yes "$(vhas "$d" $PCSET)"
  expect "v2 D3 $cmd -> PY_ALL + JS_ALL (conservative)" yes "$(vhas "$d" ruff.toml mypy.ini .coveragerc '**/ruff.toml' 'eslint.config.*' 'tsconfig*.json' '.prettierrc*' 'jest.config.*')"
done
mkd k6; verify k6 'pre-commit run -c ci/pre-commit.yaml --all-files'
expect "v2 D3 pre-commit -c ci/pre-commit.yaml -> locked" yes "$(vhas k6 ci/pre-commit.yaml)"
mkd k7; verify k7 'cd api && pre-commit run --all-files'
expect "v2 D3 cd api && pre-commit -> api/.pre-commit-config.yaml" yes "$(vhas k7 api/.pre-commit-config.yaml)"
pkg k8 '{"lint":"pre-commit run --all-files"}'; verify k8 'npm run lint'
expect "v2 D3 pre-commit inside a package.json script -> .pre-commit-config.yaml" yes "$(vhas k8 .pre-commit-config.yaml)"
mkd k9; verify k9 'echo "pre-commit is optional"'
expect "v2 D3 echo pre-commit is not a call -> []" "" "$(vep "$T/k9")"
mkrepo pc; verify pc 'pre-commit run --all-files'
printf 'repos: []\n' > "$T/pc/.pre-commit-config.yaml"; mkdir -p "$T/pc/src" "$T/pc/tests"; echo 'x = 1' > "$T/pc/src/app.py"
echo 'def test_x(): pass' > "$T/pc/tests/test_app.py"; echo 'version = 1' > "$T/pc/uv.lock"
commitall pc
new_hit pc .pre-commit-config.yaml ruff.toml src/pyproject.toml mypy.ini eslint.config.js .prettierrc
new_miss pc src/app.py tests/test_app.py uv.lock
strict pc
expect "v2 D3 strict: .pre-commit-config.yaml in denyWrite" yes "$(in_dw pc .pre-commit-config.yaml)"

# ---- lock 文件仍不是入口（加上 v2 的命令）
mkd lk2; pkg lk2 '{"lint":"eslint . && prettier --check . && stylelint \"**/*.css\"","test":"vitest run"}'
verify lk2 'npm run lint && npm test
uvx ruff check . && pipx run flake8 && uv tool run mypy src
pre-commit run --all-files'
expect "v2 L no lock file matched (cascading globs, uvx/pipx, pre-commit)" yes "$(vnomatch lk2 $LOCKS src/uv.lock web/package-lock.json packages/a/yarn.lock)"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
