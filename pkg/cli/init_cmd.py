"""harness init：把 harness 装进仓库，识别技术栈，生成 verify.sh / quick-check.sh / allow-commands.txt。

原则：
- 不覆盖你已有的文件。已有 CLAUDE.md、.claude/settings.json 时写到旁边（*.harness.*）并提示合并。
- 只改「还没配置」的验证文件；你改过的、或上次生成的，重跑都不动。
- .gitignore / .gitattributes 只追加缺的行。
- 装完检查 GitHub 分支保护：只做只读调用；能开就开 external 门卡，由你批准后自己执行命令。
"""
import datetime
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import urllib.parse
from pathlib import Path

INSTALL = ["CLAUDE.md", ".claude", ".harness", "scripts"]
# 插件模式：hooks / skills / agents 由插件提供，仓库里只放状态、脚本、规则；脚本要用的库复制到 .harness/lib/
INSTALL_PLUGIN = ["CLAUDE.md", ".claude/rules", ".harness", "scripts"]
LIB_FILES = ["harness_lib.py", "gate_github.py", "notify.sh"]
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


def install_files(pkg: Path, root: Path, notes: list, tops: list = INSTALL) -> int:
    n = 0
    for top in tops:
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


# ---------------------------------------------------------------- plugin mode
def lib_source(pkg: Path) -> Path:
    return pkg / ".claude" / "hooks" if (pkg / ".claude" / "hooks").is_dir() else pkg / "hooks"


def install_lib(pkg: Path, root: Path) -> int:
    """Code, not config: always refreshed, so re-running /harness:setup after a plugin update upgrades it."""
    dst = root / ".harness" / "lib"
    dst.mkdir(parents=True, exist_ok=True)
    n = 0
    for name in LIB_FILES:
        f = lib_source(pkg) / name
        if f.exists() and not _same(f, dst / name):
            shutil.copy2(f, dst / name)
            n += 1
    return n


def merge_permissions(src: Path, root: Path, notes: list) -> int:
    """Plugins can't carry permission rules: merge the harness deny list into the project's settings.json."""
    want = json.loads(_read(src / ".claude" / "settings.json") or "{}").get("permissions", {}).get("deny", [])
    path = root / ".claude" / "settings.json"
    msg = (".claude/settings.json 的格式和预期不同，没有改它；请手动在 permissions.deny 里加上："
           + "、".join(want))
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig")) if path.exists() else {}
    except (ValueError, OSError):
        notes.append(msg)
        return 0
    perms = data.setdefault("permissions", {}) if isinstance(data, dict) else None
    deny = perms.setdefault("deny", []) if isinstance(perms, dict) else None
    if not isinstance(deny, list):
        notes.append(msg)
        return 0
    add = [d for d in want if d not in deny]
    if add:
        deny.extend(add)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return len(add)


# ---------------------------------------------------------------- plugin upgrades
MANIFEST = Path(".harness") / "lib" / "installed.json"


def _hash(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def upgradable(rel: str) -> bool:
    """Harness-owned text that a plugin update may change. Your state (backlog, decisions, verify.sh…) never is."""
    return (rel.startswith("scripts/") or rel == "CLAUDE.md" or rel.endswith("/_TEMPLATE.md")
            or (rel.startswith(".claude/rules/") and not rel.endswith("lessons.md")))


def install_plugin_files(src: Path, root: Path, notes: list) -> int:
    """Like install_files, but remembers what it installed so a later run can upgrade files you never edited.
    A file you did edit is kept; the new version goes beside it as <file>.harness-new."""
    mpath = root / MANIFEST
    try:
        seen = json.loads(mpath.read_text(encoding="utf-8")) if mpath.exists() else {}
    except ValueError:
        seen = {}
    n, beside = 0, []
    for top in INSTALL_PLUGIN:
        base = src / top
        if not base.exists():
            continue
        for f in ([base] if base.is_file() else sorted(p for p in base.rglob("*") if p.is_file())):
            rel = f.relative_to(src).as_posix()
            if set(Path(rel).parts) & SKIP_DIRS or f.name in SKIP_FILES:
                continue
            dst = root / rel
            new_hash = _hash(f)
            if not dst.exists():
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(f, dst)
                seen[rel] = new_hash
                n += 1
                continue
            cur = _hash(dst)
            if cur == new_hash:
                seen[rel] = new_hash
                continue
            if not upgradable(rel):
                continue
            if seen.get(rel) == cur:  # still exactly what we installed last time: safe to upgrade
                shutil.copy2(f, dst)
                seen[rel] = new_hash
                n += 1
            else:
                side = dst.with_name(dst.name + ".harness-new")
                if not side.exists() or _hash(side) != new_hash:
                    shutil.copy2(f, side)
                beside.append(side.relative_to(root).as_posix())
    mpath.parent.mkdir(parents=True, exist_ok=True)
    mpath.write_text(json.dumps(seen, ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    if beside:
        notes.append("这些文件你改过，新版放在旁边，请对照合并后删掉 .harness-new：" + "、".join(beside))
    return n


# ---------------------------------------------------------------- branch protection (read-only)
BP_GATE = ".harness/gates/G-SETUP-bp.md"
GH_TIMEOUT = 10
REPO_FIELDS = "url,visibility,owner,nameWithOwner,defaultBranchRef"


class _GhTimeout(Exception):
    pass


def _gh(gh: str, args: list, cwd: Path):
    """Read-only gh call. Returns CompletedProcess, or None if gh can't be run; raises _GhTimeout."""
    try:
        return subprocess.run([gh, *args], cwd=str(cwd), capture_output=True, text=True, timeout=GH_TIMEOUT,
                              stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise _GhTimeout()
    except (OSError, subprocess.SubprocessError):
        return None


def _first_line(s: str) -> str:
    return next((l.strip() for l in (s or "").splitlines() if l.strip()), "")


def _html(s: str) -> str:
    """Escape a value shown outside code blocks in a gate card (Markdown/HTML-safe)."""
    for a, b in (("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("|", "&#124;"), ("`", "&#96;")):
        s = s.replace(a, b)
    return s


def _api_error(p) -> tuple:
    """-> (status, message) from a failed gh api call."""
    try:
        body = json.loads(p.stdout or "{}")
    except ValueError:
        body = {}
    body = body if isinstance(body, dict) else {}
    msg, status = str(body.get("message", "")), str(body.get("status", ""))
    m = re.search(r"\(HTTP (\d{3})\)", p.stderr or "")
    return status or (m.group(1) if m else ""), msg or _first_line(p.stderr)


def _logged_out(msg: str) -> bool:
    return "not logged" in msg.lower() or "auth login" in msg.lower()


def check_branch_protection(root: Path) -> dict:
    """Only the three allowlisted GET calls; never writes.
    -> {"state": protected|weak|can|plan|skip, "reason", "missing", "o", "r", "b", "h", "wf"}"""
    env_gh = os.environ.get("HARNESS_GH")
    gh = env_gh or shutil.which("gh")  # HARNESS_GH set: use only it, never fall back to PATH
    if not gh:
        return {"state": "skip", "reason": "没找到 gh（装好并 gh auth login 后重跑）"}
    rem = subprocess.run(["git", "-C", str(root), "remote"], capture_output=True, text=True)
    if not rem.stdout.strip():
        return {"state": "skip", "reason": "仓库没有远端"}
    try:
        p = _gh(gh, ["repo", "view", "--json", REPO_FIELDS], root)
    except _GhTimeout:
        return {"state": "skip", "reason": f"gh 超时（{GH_TIMEOUT} 秒），gh repo view 没有回应"}
    if p is None:
        return {"state": "skip", "reason": f"运行不了 gh（{gh}）"}
    if p.returncode != 0:
        err = _first_line(p.stderr) or _first_line(p.stdout)
        if _logged_out(err):
            return {"state": "skip", "reason": "gh 未登录（gh auth login）"}
        return {"state": "skip", "reason": f"gh repo view 失败：{err or '退出码 ' + str(p.returncode)}"}
    try:
        info = json.loads(p.stdout)
        o, r = info["nameWithOwner"].split("/", 1)
        b = (info.get("defaultBranchRef") or {})["name"]
        h = urllib.parse.urlparse(info["url"]).hostname or ""
    except (ValueError, KeyError, TypeError, AttributeError):
        return {"state": "skip", "reason": "看不懂 gh repo view 的输出"}
    if not (o and r and b and h):
        return {"state": "skip", "reason": "gh 没给出仓库名、默认分支或主机名"}
    ctx = {"o": o, "r": r, "b": b, "h": h, "wf": None}
    try:
        res = _protection(gh, root, ctx)
        if res["state"] != "skip" or res.get("reachable"):
            p = _gh(gh, ["api", "--hostname", h, f"repos/{o}/{r}/actions/permissions/workflow"], root)
            if p is not None and p.returncode == 0:
                try:
                    v = json.loads(p.stdout).get("default_workflow_permissions")
                    res["wf"] = str(v) if v else None
                except (ValueError, AttributeError):
                    pass
        return res
    except _GhTimeout:
        return {**ctx, "state": "skip", "reason": f"gh 超时（{GH_TIMEOUT} 秒），{o}/{r} 没查完"}


def _protection(gh: str, root: Path, ctx: dict) -> dict:
    o, r, b, h = ctx["o"], ctx["r"], ctx["b"], ctx["h"]
    p = _gh(gh, ["api", "--hostname", h, f"repos/{o}/{r}/branches/{urllib.parse.quote(b, safe='')}/protection"], root)
    if p is None:
        return {**ctx, "state": "skip", "reason": f"运行不了 gh（{gh}）"}
    if p.returncode == 0:
        try:
            d = json.loads(p.stdout)
            d = d if isinstance(d, dict) else {}
        except ValueError:
            d = {}
        def enabled(k):
            v = d.get(k)
            return v.get("enabled") if isinstance(v, dict) else None
        missing = []
        if enabled("allow_force_pushes") is not False:
            missing.append("禁止强推")
        if not d.get("required_pull_request_reviews"):
            missing.append("合并必须走 PR")
        if enabled("enforce_admins") is not True:
            missing.append("管理员也受约束")
        return {**ctx, "state": "weak" if missing else "protected", "missing": missing}
    status, msg = _api_error(p)
    low = msg.lower()
    if status == "404" and "not protected" in low:
        return {**ctx, "state": "can"}
    if status == "403" and "upgrade" in low and ("pro" in low or "team" in low):
        return {**ctx, "state": "plan"}
    if _logged_out(msg):
        return {**ctx, "state": "skip", "reason": f"gh 未登录（gh auth login），{o}/{r}"}
    return {**ctx, "state": "skip", "reachable": True,
            "reason": f"读不了 {o}/{r} 的 {b} 的保护设置：{msg or '未知错误'}" + (f"（HTTP {status}）" if status else "")}


def _wf_cmd(o: str, r: str, h: str) -> str:
    q = shlex.quote
    return f"gh api --hostname {q(h)} -X PUT {q(f'repos/{o}/{r}/actions/permissions/workflow')} -f default_workflow_permissions=read"


def bp_gate_text(o: str, r: str, b: str, h: str, wf) -> str:
    q = shlex.quote
    bpath = f"repos/{o}/{r}/branches/{urllib.parse.quote(b, safe='')}/protection"
    bp = (f"gh api --hostname {q(h)} -X PUT {q(bpath)} -H \"Accept: application/vnd.github+json\" "
          "-F required_status_checks=null -F enforce_admins=true "
          "-F \"required_pull_request_reviews[required_approving_review_count]=0\" "
          "-F restrictions=null -F allow_force_pushes=false -F allow_deletions=false")
    fix_wf = wf != "read"
    cmds = bp + ("\n" + _wf_cmd(o, r, h) if fix_wf else "")
    eo, er, eb, eh = _html(o), _html(r), _html(b), _html(h)
    wf_row = (f"| Actions 默认权限 | {_html(wf)}（建议改只读） | ⚠️ |\n" if wf and fix_wf
              else "| Actions 默认权限 | 没读到（命令照样改成只读） | ⚠️ |\n" if fix_wf else "")
    n = "两条命令" if fix_wf else "这条命令"
    wf_effect = "；Actions 默认只读" if fix_wf else ""
    today = datetime.date.today().isoformat()
    return f"""---
id: G-SETUP-bp
task:
kind: external
status: open
created: {today}
urgency: normal
recommended: A
decided_by: human
review_minutes: 3
default_if_no_answer: 不开；strict 模式继续在本机挡住合并
blocks: []
answer:
approve_options: [A]
then:
then_policy:
then_rules: []
pr:
issue:
---

# G-SETUP-bp 在 GitHub 上给 {eo}/{er} 的 {eb} 开分支保护吗？

**为什么需要你：** 改 GitHub 仓库设置是对外操作，harness 不替你执行；只有你能批准并运行。

**预计耗时：** 3 分钟

**注意：** 仓库规则集（rulesets）可能仍在保护这个分支，开之前先在 Settings → Rules 看一眼。

## 怎么检查
```bash
{cmds}
```
1. 确认仓库（{eh} 上的 {eo}/{er}）和分支（{eb}）是对的。
2. 选 A：在你自己的终端运行上面的{n}（需要仓库管理员权限）。
3. 验证：`gh api --hostname {q(h)} {q(bpath)}` 能读到设置（不再是 404）。

## 机器已预检
| 项目 | 结果 | 通过 |
|---|---|---|
| 分支保护（只读查询） | {eb} 未开保护（HTTP 404 Branch not protected） | ✅ |
{wf_row}| 写调用 | 0 次（harness init 只读） | ✅ |

## 选项
- **A（推荐）**：由你执行上面的{n}开启 — 后果：{eb} 必须走 PR（不强制别人审批，一个人也能合并自己的 PR）、禁止强推和删除、管理员也受约束{wf_effect}
- **B**：先不开 — 后果：只靠 strict 模式在本机挡住合并，GitHub 上仍可直接推 {eb}

**回复格式：** `G-SETUP-bp: A` 或 `G-SETUP-bp: B，<备注>`
"""


def branch_protection(root: Path, dry: bool) -> None:
    """Prints exactly one line mentioning 分支保护 (+ maybe one Actions line). Never changes init's exit code."""
    try:
        res = check_branch_protection(root)
    except Exception as e:  # noqa: BLE001 — a check must never break init
        res = {"state": "skip", "reason": f"{type(e).__name__}: {e}"}
    st = res["state"]
    o, r, b = res.get("o"), res.get("r"), res.get("b")
    wf_in_card = False
    if st == "protected":
        print(f"✓ 分支保护已开启：{o}/{r} 的 {b}")
    elif st == "weak":
        print(f"• 分支保护已开但不完整：{o}/{r} 的 {b} 缺少：{'、'.join(res['missing'])}")
    elif st == "plan":
        print(f"• 分支保护开不了：{o}/{r} 是私有仓库，GitHub Free 上没有分支保护（需要 Pro/Team）；strict 模式已在本机挡住合并。")
    elif st == "can":
        gate = root / BP_GATE
        if gate.exists():
            m = re.search(r"^status:[ \t]*([^\s#]*)", _read(gate), re.M)
            print(f"→ 分支保护可以开：门卡 {BP_GATE} 已存在（status: {(m.group(1) if m else '') or '未知'}），{o}/{r} 的 {b}")
        elif dry:
            print(f"→ 分支保护可以开：会开门卡 {BP_GATE}（{o}/{r} 的 {b}），批准后照门卡里的命令执行")
            wf_in_card = True
        else:
            try:
                gate.parent.mkdir(parents=True, exist_ok=True)
                gate.write_text(bp_gate_text(o, r, b, res["h"], res.get("wf")), encoding="utf-8")
                print(f"→ 分支保护可以开：已开门卡 {BP_GATE}（{o}/{r} 的 {b}），批准后照门卡里的命令执行")
                wf_in_card = True
            except OSError as e:
                print(f"跳过分支保护检查：写不了门卡 {BP_GATE}（{e}），{o}/{r}")
    else:
        print(f"跳过分支保护检查：{res.get('reason') or '未知原因'}")
    wf = res.get("wf")
    if wf and wf != "read" and not wf_in_card:
        print(f"→ Actions 默认权限是 {wf}：建议改只读：{_wf_cmd(o, r, res['h'])}")


# ---------------------------------------------------------------- entry
def main(argv: list, pkg_root: str) -> int:
    yes = "--yes" in argv or "-y" in argv
    plugin = "--plugin" in argv
    dry = "--dry-run" in argv
    if "--target" in argv and (argv.index("--target") + 1 >= len(argv) or argv[argv.index("--target") + 1].startswith("-")):
        print("✗ --target 后面要跟仓库路径，例如 --target .", file=sys.stderr)
        return 2
    target = Path(argv[argv.index("--target") + 1]) if "--target" in argv else Path.cwd()
    pkg = Path(pkg_root)
    src = pkg / "payload" if (pkg / "payload").is_dir() else pkg  # the plugin ships the install files under payload/
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
    if plugin:
        print("插件模式：hooks、skills、子代理由插件提供；仓库里写入 .harness/、scripts/、CLAUDE.md、.claude/rules/，"
              "库复制到 .harness/lib/，.claude/settings.json 只合并权限 deny 列表。")
    if d["verify"]:
        print("完整验证（.harness/verify.sh）：\n  " + "\n  ".join(d["verify"]))
    if d["allow"]:
        print("以后不再问你的命令：\n  " + "\n  ".join(d["allow"]))
    if dry:
        branch_protection(root, dry=True)
        print("（--dry-run：没有写入任何文件）")
        return 0
    if not yes:
        try:
            ans = input("照这样装？[Y/n] ").strip().lower()
        except EOFError:
            ans = "n"
        if ans not in ("", "y", "yes"):
            print("没有改动任何文件。")
            return 1
    notes: list = []
    if plugin:
        if (root / ".claude" / "hooks" / "harness_lib.py").exists():
            notes.append("仓库里已有 harness 的 hooks（.claude/hooks/）。装了插件后每个 hook 会跑两次（例如门卡被发两次 Issue）："
                         "请删掉 .claude/hooks/、.claude/skills/、.claude/agents/ 里 harness 的文件，并去掉 settings.json 里的 hooks。")
        n = install_lib(pkg, root)  # first: the manifest of installed files lives in .harness/lib
        n += install_plugin_files(src, root, notes)
        pm = merge_permissions(src, root, notes)
        lk = root / ".harness" / "locks.txt"
        if not any(l.split("#")[0].strip() == ".harness/lib/**" for l in _read(lk).splitlines()):
            append_missing(lk, [".harness/lib/**             # 插件模式下的库副本，由 /harness:setup 更新，不直接改"])
        print(f"✓ 权限 deny 列表 +{pm} 条")
    else:
        n = install_files(src, root, notes)
    gi = append_missing(root / ".gitignore", GITIGNORE)
    ga = append_missing(root / ".gitattributes", [l for l in _read(src / ".gitattributes").splitlines() if l.strip()])
    written = write_configs(root, d, notes)
    for name in ("scripts",):
        for f in (root / name).glob("*.sh"):
            f.chmod(f.stat().st_mode | 0o111)
    print(f"✓ 装好 {n} 个文件；.gitignore +{gi} 行，.gitattributes +{ga} 行；生成：{', '.join(written) or '无（已配置过）'}")
    for m in notes:
        print("• " + m)
    branch_protection(root, dry=False)
    nxt = "/harness:task-align" if plugin else "/task-align"
    print(f"下一步：git add -A && git commit -m 'chore: add harness'，然后在 Claude Code 里 {nxt} 你的第一个需求。")
    return 0
