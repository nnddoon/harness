"""harness doctor / down：看 harness 在这台电脑上跑着什么，一键停掉。

  harness doctor [--repo DIR]   定时任务（含到期日）、在跑的调度器与 bot、久未动的 worktree、久未答的门卡、沙箱依赖
  harness down   [--repo DIR]   停掉 run/*.pid 里存活的进程、删 pid 文件、移除本仓库的 harness 定时任务（幂等）

DIR 可以是主仓库或它的 worktree（默认当前目录）。crontab 经 ${HARNESS_CRONTAB:-crontab}；
「现在」可用 HARNESS_NOW（Unix 秒）覆盖，日期一律按 UTC。只碰带 `# harness` 标记的定时任务，不删 worktree。
"""
import datetime as dt
import importlib.util
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

PKG = Path(__file__).resolve().parents[1]
STALE_WT_DAYS = 7
STALE_GATE_DAYS = 3
EXPIRES_RE = re.compile(r"expires=(\d{4}-\d{2}-\d{2})")


def _lib(repo: Path):
    # 优先用包自带的库：仓库里的副本可能是旧版（没有 state_dir 等）
    for d in (PKG / ".claude/hooks", PKG / "hooks", repo / ".claude/hooks", repo / ".harness/lib"):
        p = d / "harness_lib.py"
        if p.exists():
            sys.dont_write_bytecode = True
            spec = importlib.util.spec_from_file_location("harness_lib_doctor", p)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    raise SystemExit("找不到 harness_lib.py：插件安装不完整？")


def now() -> float:
    v = os.environ.get("HARNESS_NOW", "").strip()
    try:
        return float(v) if v else time.time()
    except ValueError:
        return time.time()


def today() -> str:
    return dt.datetime.fromtimestamp(now(), dt.timezone.utc).date().isoformat()


def main_repo(d: Path) -> Path:
    try:
        out = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                             cwd=str(d), capture_output=True, text=True, timeout=10)
        if out.returncode == 0 and out.stdout.strip():
            return Path(out.stdout.strip()).parent
    except Exception:
        pass
    return d.resolve()


# ---------------------------------------------------------------- crontab
def _crontab() -> str:
    return os.environ.get("HARNESS_CRONTAB") or "crontab"


def cron_read() -> list | None:
    """crontab 的行；还没有 crontab（-l 失败）→ None。"""
    try:
        out = subprocess.run([_crontab(), "-l"], capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    return out.stdout.splitlines() if out.returncode == 0 else None


def cron_write(lines: list) -> bool:
    text = "".join(f"{l}\n" for l in lines)
    try:
        return subprocess.run([_crontab(), "-"], input=text, text=True, timeout=10).returncode == 0
    except Exception:
        return False


def is_harness(line: str) -> bool:
    return "# harness" in line


def is_mine(line: str, main: Path) -> bool:
    return f"# harness repo={main} " in line


# ---------------------------------------------------------------- pid files
def pid_files(run: Path) -> list:
    return sorted(run.glob("*.pid")) if run.is_dir() else []


def read_pid(p: Path) -> int | None:
    try:
        s = p.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return int(s) if s.isdigit() and int(s) > 1 else None


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


# ---------------------------------------------------------------- sections
def sec_cron(main: Path) -> list:
    out, t = [], today()
    for l in cron_read() or []:
        if not is_harness(l):
            continue
        m = EXPIRES_RE.search(l)
        out.append(l + ("    已过期" if m and m.group(1) < t else "" if m else "    （没有 expires=，不会自动到期）"))
    note = main / ".harness" / "reports" / "expired-cron.txt"
    if note.is_file():
        out += [l for l in note.read_text(encoding="utf-8").splitlines() if l.strip()]
    return out


def sec_procs(run: Path) -> list:
    out = []
    for p in pid_files(run):
        pid = read_pid(p)
        if pid is None:
            out.append(f"{p.name}  内容无效（不是进程号），不处理：{p}")
        elif alive(pid):
            out.append(f"{pid}  {p.name}")
        else:
            out.append(f"{pid}  {p.name}  已退出（已删除 pid 文件）")
            p.unlink(missing_ok=True)
    return out


def sec_worktrees(lib, main: Path) -> list:
    out, t = [], now()
    for path, branch in lib.worktrees(main):
        if path.resolve() == main.resolve() or not path.is_dir():
            continue
        try:
            last = float(lib._git(["log", "-1", "--format=%ct"], path) or 0)
        except ValueError:
            last = 0.0
        days = (t - max(last, path.stat().st_mtime)) / 86400
        if days > STALE_WT_DAYS:
            out.append(f"{path}  {branch or '（detached）'}  {int(days)} 天没动（只列出，不删除）")
    return out


def _ts(v) -> float | None:
    s = str(v or "").strip()
    try:
        d = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        try:
            d = dt.datetime.fromisoformat(s[:10])
        except ValueError:
            return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return d.timestamp()


def sec_gates(lib, main: Path) -> list:
    out, t = [], now()
    for g in lib.gates(main):
        c = _ts(g.get("created"))
        if g.get("status") != "open" or c is None:
            continue
        days = (t - c) / 86400
        if days > STALE_GATE_DAYS:
            gid = g.get("id") or Path(g["_path"]).stem
            out.append(f"{gid}  {g.get('task', '')}  {int(days)} 天没答")
    return out


def doctor(repo: Path) -> int:
    lib = _lib(repo)
    main = main_repo(repo)
    run = lib.state_dir(main) / "run"
    sections = [
        ("定时任务", lambda: sec_cron(main)),
        ("在跑的进程", lambda: sec_procs(run)),
        ("久未动的 worktree", lambda: sec_worktrees(lib, main)),
        ("久未答的门卡", lambda: sec_gates(lib, main)),
        ("沙箱依赖", lambda: [lib.sandbox_problem(lib.detect_platform()) or "ok"]),
    ]
    for i, (title, fn) in enumerate(sections):
        try:
            items = fn()
        except Exception as e:  # doctor 自己不该挂：报出来，继续下一段
            items = [f"检查失败：{e}"]
        print(("\n" if i else "") + f"## {title}")
        print("\n".join(items) if items else "（无）")
    return 0


def down(repo: Path) -> int:
    lib = _lib(repo)
    main = main_repo(repo)
    run = lib.state_dir(main) / "run"
    did = []
    for p in pid_files(run):
        pid = read_pid(p)
        if pid is not None and alive(pid):
            try:
                os.kill(pid, signal.SIGTERM)
                did.append(f"已停止 {pid}（{p.name}）")
            except OSError as e:
                did.append(f"停止 {pid}（{p.name}）失败：{e}")
        p.unlink(missing_ok=True)
        if pid is None:
            did.append(f"已删除无效的 pid 文件 {p.name}")
    lines = cron_read()
    if lines is not None:
        mine = [l for l in lines if is_harness(l) and is_mine(l, main)]
        if mine:
            if cron_write([l for l in lines if l not in mine]):
                did += [f"已移除定时任务：{l}" for l in mine]
            else:
                did.append("移除定时任务失败：crontab 写入出错")
    print("\n".join(did) if did else "没有要停的")
    return 0


def _repo_arg(argv: list) -> Path:
    if "--repo" in argv:
        i = argv.index("--repo")
        if i + 1 < len(argv):
            return Path(argv[i + 1]).resolve()
    return Path.cwd()


def main(argv: list, pkg_root: str = "") -> int:
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    return doctor(_repo_arg(argv))


def main_down(argv: list, pkg_root: str = "") -> int:
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    return down(_repo_arg(argv))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], str(PKG)))
