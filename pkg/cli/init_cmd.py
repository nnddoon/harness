"""harness init：把 harness 装进仓库，识别技术栈，生成 verify.sh / quick-check.sh / allow-commands.txt。

原则：
- 不覆盖你已有的文件。已有 CLAUDE.md、.claude/settings.json 时写到旁边（*.harness.*）并提示合并。
- 只改「还没配置」的验证文件；你改过的、或上次生成的，重跑都不动。
- .gitignore / .gitattributes 只追加缺的行。
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

INSTALL = ["CLAUDE.md", ".claude", ".harness", "scripts"]
SKIP_DIRS = {"__pycache__", "worktrees", "logs", "reports"}
SKIP_FILES = {"settings.local.json", "STATUS.md", "auto-decide.txt"}
GITIGNORE = [".claude/worktrees/", ".claude/settings.local.json", ".harness/logs/", "__pycache__/"]
STUB_MARKERS = {
    "verify.sh": "verify.sh 未配置",
    "quick-check.sh": "安装时改成你的项目命令",
    "allow-commands.txt": "安装时按你的项目改",
}
HARNESS_OWN = ".claude,.harness,scripts/testdata"  # harness 自己装进来的文件，不算你项目的 lint/类型检查范围
HEADER = "# 由 harness init 生成（检测到：{stack}）。可以随时改；重跑 init 不会覆盖。\n"


# ---------------------------------------------------------------- detection
def _read(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def detect(root: Path) -> dict:
    """-> {"stack": str, "verify": [cmd], "quick": str (case body) , "allow": [regex]}；没认出时 stack 为空。"""
    py_files = ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "requirements-dev.txt"]
    if any((root / f).exists() for f in py_files):
        deps = "\n".join(_read(root / f) for f in py_files).lower()
        verify, allow = [], [r"^python3 -m (pytest|py_compile)\b"]
        if "pytest" in deps or (root / "tests").is_dir() or (root / "conftest.py").exists():
            verify.append("pytest -q")
            allow.append(r"^pytest\b")
        if "ruff" in deps:
            verify.append(f"ruff check . --extend-exclude {HARNESS_OWN}")
            allow.append(r"^ruff\b")
        if "mypy" in deps:
            verify.append("mypy . --exclude '(^|/)(\\.claude|\\.harness|scripts/testdata)/'")
            allow.append(r"^mypy\b")
        quick = '  *.py) python3 -B -m py_compile "$1"' + (' && ruff check "$1"' if "ruff" in deps else "") + " ;;"
        return {"stack": "python", "verify": verify, "quick": quick, "allow": allow}
    pkg = root / "package.json"
    if pkg.exists():
        try:
            data = json.loads(_read(pkg) or "{}")
        except ValueError:
            data = {}
        pm = ("pnpm" if (root / "pnpm-lock.yaml").exists() else "yarn" if (root / "yarn.lock").exists()
              else "bun" if (root / "bun.lockb").exists() else "npm")
        scripts = data.get("scripts") or {}
        names = [s for s in ("test", "lint", "typecheck", "type-check", "build") if s in scripts]
        verify = [f"{pm} run {s}" for s in names]
        allow = [rf"^{pm} (run )?({'|'.join(names)})\b"] if names else []
        deps = {**(data.get("dependencies") or {}), **(data.get("devDependencies") or {})}
        quick = ""
        if "eslint" in deps:
            runner = {"pnpm": "pnpm exec", "yarn": "yarn", "bun": "bunx"}.get(pm, "npx")
            quick = f'  *.ts|*.tsx|*.js|*.jsx|*.mjs) {runner} eslint --max-warnings 0 "$1" ;;'
            allow.append(rf"^{runner} eslint\b")
        return {"stack": f"node/{pm}", "verify": verify, "quick": quick, "allow": allow}
    return {"stack": "", "verify": [], "quick": "", "allow": []}


# ---------------------------------------------------------------- install
def _same(a: Path, b: Path) -> bool:
    try:
        return a.read_bytes() == b.read_bytes()
    except OSError:
        return False


def install_files(pkg: Path, root: Path, notes: list) -> int:
    n = 0
    for top in INSTALL:
        src = pkg / top
        if not src.exists():
            continue
        items = [src] if src.is_file() else sorted(p for p in src.rglob("*") if p.is_file())
        for f in items:
            rel = f.relative_to(pkg)
            if set(rel.parts) & SKIP_DIRS or f.name in SKIP_FILES:
                continue
            dst = root / rel
            if dst.exists():
                if _same(f, dst):
                    continue
                if rel.as_posix() in ("CLAUDE.md", ".claude/settings.json"):
                    side = dst.with_name(dst.stem + ".harness" + dst.suffix)
                    shutil.copy2(f, side)
                    notes.append(f"你已有 {rel.as_posix()}，harness 版本写在 {side.relative_to(root).as_posix()}，"
                                 "请把两者合并（hooks 在 settings 里，规则在 CLAUDE.md 里）。")
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, dst)
            n += 1
    return n


def append_missing(path: Path, lines: list) -> int:
    old = _read(path)
    have = set(old.splitlines())
    add = [l for l in lines if l and l not in have]
    if add:
        with path.open("a", encoding="utf-8") as fh:
            if old and not old.endswith("\n"):
                fh.write("\n")
            fh.write("\n".join(add) + "\n")
    return len(add)


def _is_stub(path: Path) -> bool:
    return (not path.exists()) or STUB_MARKERS[path.name] in _read(path)


def write_configs(root: Path, d: dict, notes: list) -> list:
    h = root / ".harness"
    written = []
    if d["verify"] and _is_stub(h / "verify.sh"):
        body = ("#!/usr/bin/env bash\n" + HEADER.format(stack=d["stack"]) +
                "set -e\ncd \"$(git rev-parse --show-toplevel)\"\n" + "\n".join(d["verify"]) + "\n")
        (h / "verify.sh").write_text(body, encoding="utf-8")
        written.append("verify.sh")
    if d["quick"] and _is_stub(h / "quick-check.sh"):
        body = ("#!/usr/bin/env bash\n" + HEADER.format(stack=d["stack"]) +
                "# 改完一个文件立刻跑，只检查这一个文件；非 0 = 结果回给 Claude。\n"
                f'case "$1" in\n{d["quick"]}\nesac\n')
        (h / "quick-check.sh").write_text(body, encoding="utf-8")
        written.append("quick-check.sh")
    if d["allow"] and _is_stub(h / "allow-commands.txt"):
        body = (HEADER.format(stack=d["stack"]) +
                "# 这些命令不再弹权限确认（每行一个正则）。危险命令仍会被护栏 hook 拦下。\n" + "\n".join(d["allow"]) + "\n")
        (h / "allow-commands.txt").write_text(body, encoding="utf-8")
        written.append("allow-commands.txt")
    for name in ("verify.sh", "quick-check.sh"):
        p = h / name
        if p.exists():
            p.chmod(p.stat().st_mode | 0o111)
    if not d["stack"]:
        notes.append("没认出技术栈（不是 Python 也不是 Node）。请自己编辑 .harness/verify.sh、quick-check.sh、"
                     "allow-commands.txt；在那之前夜间整合会拒绝合并。")
    return written


# ---------------------------------------------------------------- entry
def main(argv: list, pkg_root: str) -> int:
    yes = "--yes" in argv or "-y" in argv
    target = Path(argv[argv.index("--target") + 1]) if "--target" in argv else Path.cwd()
    pkg = Path(pkg_root)
    try:
        top = subprocess.run(["git", "-C", str(target), "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError, NotADirectoryError):
        print(f"✗ {target} 不是 git 仓库。先 git init，或用 --target 指到仓库里。", file=sys.stderr)
        return 1
    root = Path(top)
    d = detect(root)
    print(f"仓库：{root}")
    print(f"技术栈：{d['stack'] or '没认出'}")
    if d["verify"]:
        print("完整验证（.harness/verify.sh）：\n  " + "\n  ".join(d["verify"]))
    if d["allow"]:
        print("以后不再问你的命令：\n  " + "\n  ".join(d["allow"]))
    if not yes:
        try:
            ans = input("照这样装？[Y/n] ").strip().lower()
        except EOFError:
            ans = "n"
        if ans not in ("", "y", "yes"):
            print("没有改动任何文件。")
            return 1
    notes: list = []
    n = install_files(pkg, root, notes)
    gi = append_missing(root / ".gitignore", GITIGNORE)
    ga = append_missing(root / ".gitattributes", [l for l in _read(pkg / ".gitattributes").splitlines() if l.strip()])
    written = write_configs(root, d, notes)
    for name in ("scripts",):
        for f in (root / name).glob("*.sh"):
            f.chmod(f.stat().st_mode | 0o111)
    print(f"✓ 装好 {n} 个文件；.gitignore +{gi} 行，.gitattributes +{ga} 行；生成：{', '.join(written) or '无（已配置过）'}")
    for m in notes:
        print("• " + m)
    print("下一步：git add -A && git commit -m 'chore: add harness'，然后在 Claude Code 里 /task-align 你的第一个需求。")
    return 0
