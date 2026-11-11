#!/usr/bin/env bash
# T-001 验收：harness init 识别技术栈、生成配置、不覆盖已有文件、可重跑。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-init.XXXXXX")"; trap 'rm -rf "$T"' EXIT
N=0; FAILS=0
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got $3)"; FAILS=$((FAILS+1)); fi; }
has() { grep -qF -- "$2" "$1" 2>/dev/null && echo yes || echo no; }
count() { grep -cxF -- "$2" "$1" 2>/dev/null || true; }
init() { python3 "$SRC/bin/harness" init --yes --target "$1"; }

# ---------------------------------------------------------------- Python 仓库
PY="$T/py"; mkdir -p "$PY/tests" && cd "$PY" && git init -q -b main
printf '[project]\nname = "demo"\n[project.optional-dependencies]\ndev = ["pytest", "ruff", "mypy"]\n' > pyproject.toml
printf 'def test_ok():\n    assert True\n' > tests/test_ok.py
printf '# mine\n' > CLAUDE.md
mkdir -p .claude && printf '{"permissions": {"allow": []}}\n' > .claude/settings.json
OUT="$(init "$PY" 2>&1)"; RC=$?
expect "py: init exits 0" 0 "$RC"
expect "py: verify.sh runs pytest" yes "$(has .harness/verify.sh 'pytest')"
expect "py: verify.sh runs ruff" yes "$(has .harness/verify.sh 'ruff check')"
expect "py: verify.sh runs mypy" yes "$(has .harness/verify.sh 'mypy')"
expect "py: verify.sh no longer the unconfigured stub" no "$(has .harness/verify.sh 'verify.sh 未配置')"
expect "py: verify.sh is executable" yes "$([ -x .harness/verify.sh ] && echo yes || echo no)"
expect "py: verify.sh passes on the demo repo" 0 "$(bash .harness/verify.sh >/dev/null 2>&1; echo $?)"
expect "py: quick-check handles .py" yes "$(has .harness/quick-check.sh '*.py)')"
expect "py: quick-check passes on a clean file" 0 "$(bash .harness/quick-check.sh tests/test_ok.py >/dev/null 2>&1; echo $?)"
expect "py: allow-commands lets pytest run" yes "$(has .harness/allow-commands.txt '^pytest')"
expect "py: existing CLAUDE.md kept" "# mine" "$(head -1 CLAUDE.md)"
expect "py: harness CLAUDE.md written beside it" yes "$([ -f CLAUDE.harness.md ] && echo yes || echo no)"
expect "py: existing settings.json kept" yes "$(has .claude/settings.json '"allow": []')"
expect "py: harness settings written beside it" yes "$([ -f .claude/settings.harness.json ] && echo yes || echo no)"
expect "py: tells you to merge the two" yes "$(printf '%s' "$OUT" | grep -q 'settings.harness.json' && echo yes || echo no)"
expect "py: hooks installed" yes "$([ -f .claude/hooks/protect_paths.py ] && echo yes || echo no)"
expect "py: scripts installed" yes "$([ -x scripts/harness-loop.sh ] && echo yes || echo no)"
expect "py: worktrees ignored" 1 "$(count .gitignore '.claude/worktrees/')"
expect "py: union merge for decisions" 1 "$(count .gitattributes '.harness/decisions.md merge=union')"
printf '\n# 我自己加的\n' >> .harness/verify.sh
init "$PY" >/dev/null 2>&1
expect "py: rerun keeps your verify.sh edits" yes "$(has .harness/verify.sh '我自己加的')"
expect "py: rerun does not duplicate .gitignore" 1 "$(count .gitignore '.claude/worktrees/')"
expect "py: rerun does not duplicate .gitattributes" 1 "$(count .gitattributes '.harness/decisions.md merge=union')"

# ---------------------------------------------------------------- Node 仓库（pnpm）
NODE="$T/node"; mkdir -p "$NODE" && cd "$NODE" && git init -q -b main
cat > package.json <<'JSON'
{"name":"demo","scripts":{"test":"node -e \"process.exit(0)\"","lint":"node -e \"process.exit(0)\"","typecheck":"node -e \"process.exit(0)\""},"devDependencies":{"eslint":"^9.0.0"}}
JSON
: > pnpm-lock.yaml
init "$NODE" >/dev/null 2>&1
expect "node: verify uses pnpm test" yes "$(has .harness/verify.sh 'pnpm run test')"
expect "node: verify uses pnpm lint" yes "$(has .harness/verify.sh 'pnpm run lint')"
expect "node: verify uses pnpm typecheck" yes "$(has .harness/verify.sh 'pnpm run typecheck')"
expect "node: verify.sh passes" 0 "$(bash .harness/verify.sh >/dev/null 2>&1; echo $?)"
expect "node: quick-check lints ts with eslint" yes "$(has .harness/quick-check.sh 'eslint')"
expect "node: allow-commands lets pnpm scripts run" yes "$(has .harness/allow-commands.txt '^pnpm (run )?(test|lint|typecheck)')"
expect "node: CLAUDE.md installed when absent" yes "$([ -f CLAUDE.md ] && [ ! -f CLAUDE.harness.md ] && echo yes || echo no)"

# ---------------------------------------------------------------- npm 与未知技术栈
NPM="$T/npm"; mkdir -p "$NPM" && cd "$NPM" && git init -q -b main
printf '{"name":"x","scripts":{"test":"node -e \\"process.exit(0)\\""}}\n' > package.json
init "$NPM" >/dev/null 2>&1
expect "npm: verify uses npm run test" yes "$(has .harness/verify.sh 'npm run test')"
UNK="$T/unk"; mkdir -p "$UNK" && cd "$UNK" && git init -q -b main
OUT="$(init "$UNK" 2>&1)"
expect "unknown stack: verify.sh stays unconfigured" yes "$(has .harness/verify.sh 'verify.sh 未配置')"
expect "unknown stack: says what to fill" yes "$(printf '%s' "$OUT" | grep -q '没认出' && echo yes || echo no)"

# ---------------------------------------------------------------- 不是 git 仓库
NG="$T/nogit"; mkdir -p "$NG"
init "$NG" >/dev/null 2>&1; RC=$?
expect "not a git repo: refuses" 1 "$([ $RC -ne 0 ] && echo 1 || echo 0)"
expect "not a git repo: writes nothing" no "$([ -e "$NG/.harness" ] && echo yes || echo no)"

echo "$((N-FAILS))/$N passed"
[ "$FAILS" -eq 0 ]
