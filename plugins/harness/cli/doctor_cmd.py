"""harness doctor / down：看 harness 在这台电脑上跑着什么，一键停掉。

  harness doctor [--repo DIR]   定时任务（含到期日）、在跑的调度器与 bot、久未动的 worktree、久未答的门卡、沙箱依赖
  harness down   [--repo DIR] [--prune-audit]
                                停掉 run/*.pid 里还在跑的 harness 进程（连同子进程，只发 SIGTERM）、删 pid 文件、
                                移除本仓库的 harness 定时任务（含旧格式）；幂等。有进程停不掉 → 退出码 1
                                --prune-audit：另外删掉超过保留期（HARNESS_AUDIT_DAYS，默认 30 天）的审计日志

DIR 可以是主仓库或它的 worktree（默认当前目录）。crontab 经 ${HARNESS_CRONTAB:-crontab}；
「现在」可用 HARNESS_NOW（Unix 秒）覆盖，日期一律按 UTC。只碰带 `# harness` 标记的定时任务，不删 worktree。
"""
import contextlib
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


@contextlib.contextmanager
def cron_lock():
    """和 gate-sync.sh 共用 ${XDG_STATE_HOME:-~/.local/state}/harness/crontab.lock，读-改-写期间互斥。"""
    try:
        import fcntl
        d = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state") / "harness"
        d.mkdir(parents=True, exist_ok=True)
        f = open(d / "crontab.lock", "a")
    except Exception:  # 没有 fcntl（Windows）或建不了锁文件：不加锁
        yield
        return
    with f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX)
        except OSError:
            pass
        yield


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


def is_legacy(line: str) -> bool:
    """T-013 之前的 install-cron 写的行：有 gate-sync --resume、没有 # harness 标记。"""
    return not is_harness(line) and "scripts/gate-sync.sh --resume" in line


def is_mine(line: str, main: Path) -> bool:
    """本仓库的 harness 行，或本仓库的旧格式行。"""
    return f"# harness repo={main} " in line or (is_legacy(line) and f'cd "{main}" ' in line)


# ---------------------------------------------------------------- processes
PROC = Path("/proc/self/stat").exists()


def _stat(pid: int) -> list | None:
    """/proc/<pid>/stat 最后一个 ')' 之后的字段（[0]=状态，[1]=ppid，[19]=starttime）。"""
    try:
        s = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    return s[s.rfind(")") + 2:].split()


def _ps(pid: int, field: str) -> str:
    try:
        return subprocess.run(["ps", "-o", f"{field}=", "-p", str(pid)], capture_output=True,
                              text=True, timeout=10).stdout.strip()
    except Exception:
        return ""


def running(pid: int) -> bool:
    """进程存在且不是僵尸。"""
    if PROC:
        st = _stat(pid)
        return bool(st) and st[0] not in ("Z", "X")
    try:
        os.kill(pid, 0)
    except PermissionError:
        pass
    except OSError:
        return False
    return not _ps(pid, "stat").startswith("Z")


def starttime(pid: int) -> str | None:
    st = _stat(pid) if PROC else None
    return st[19] if st and len(st) > 19 else None


def cmdline(pid: int) -> str:
    if PROC:
        try:
            return Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            return ""
    return _ps(pid, "command")


def same(pid: int, start: str | None) -> bool:
    """还是那个进程：在跑，且（能比时）启动时刻没变。"""
    return running(pid) and (start is None or not PROC or starttime(pid) == start)


def ours(pid: int, start: str | None) -> bool:
    """pid 文件记的还是 harness 的进程（防 pid 复用）。"""
    return same(pid, start) and "harness" in cmdline(pid)


def ppid_map() -> dict:
    m = {}
    if PROC:
        for d in Path("/proc").iterdir():
            if d.name.isdigit():
                st = _stat(int(d.name))
                if st and len(st) > 1 and st[1].isdigit():
                    m[int(d.name)] = int(st[1])
        return m
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return m
    for line in out.splitlines():
        a = line.split()
        if len(a) == 2 and a[0].isdigit() and a[1].isdigit():
            m[int(a[0])] = int(a[1])
    return m


def descendants(pid: int, m: dict) -> list:
    kids, todo = [], [pid]
    while todo:
        cur = todo.pop()
        for c, pp in m.items():
            if pp == cur and c not in kids and c != pid:
                kids.append(c)
                todo.append(c)
    return kids


def ancestors(pid: int, m: dict) -> set:
    out = set()
    while pid in m and pid not in out and pid > 1:
        out.add(pid)
        pid = m[pid]
    return out


# ---------------------------------------------------------------- pid files
def pid_files(run: Path) -> list:
    return sorted(run.glob("*.pid")) if run.is_dir() else []


def read_pid(p: Path) -> tuple | None:
    """'<pid> [<starttime>]' → (pid, starttime|None)；内容无效 → None。"""
    try:
        a = p.read_text(encoding="utf-8").split()
    except OSError:
        return None
    if not 1 <= len(a) <= 2 or not all(x.isdigit() for x in a) or int(a[0]) <= 1:
        return None
    return int(a[0]), (a[1] if len(a) == 2 else None)


# ---------------------------------------------------------------- sections
def sec_cron(main: Path) -> list:
    out, t = [], today()
    for l in cron_read() or []:
        if is_legacy(l):
            out.append(l + "    旧格式（没有到期日；重跑 scripts/gate-sync.sh install-cron 或 harness down 换掉）")
            continue
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
        rec = read_pid(p)
        if rec is None:
            out.append(f"{p.name}  内容无效（不是进程号），不处理：{p}")
        elif ours(*rec):
            out.append(f"{rec[0]}  {p.name}")
        else:
            out.append(f"{rec[0]}  {p.name}  已退出（或 pid 已被别的进程复用；已删除 pid 文件）")
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


def human_size(n: int) -> str:
    for unit in ("B", "KB", "MB"):
        if n < 1024:
            return f"{n} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GB"


def sec_audit(lib, main: Path) -> list:
    size, files = lib.audit_size(main)
    return [f"{human_size(size)}，{files} 个日文件（保留 {lib.audit_keep_days()} 天；"
            f"清理：harness down --prune-audit）：{lib.state_dir(main) / 'audit'}"]


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
    if lib.audit_size(main)[1]:  # 只在已有审计日志时报（没有日志就没有可报的）
        sections.append(("审计日志", lambda: sec_audit(lib, main)))
    for i, (title, fn) in enumerate(sections):
        try:
            items = fn()
        except Exception as e:  # doctor 自己不该挂：报出来，继续下一段
            items = [f"检查失败：{e}"]
        print(("\n" if i else "") + f"## {title}")
        print("\n".join(items) if items else "（无）")
    return 0


def down(repo: Path, prune_audit: bool = False) -> int:
    lib = _lib(repo)
    main = main_repo(repo)
    run = lib.state_dir(main) / "run"
    did, rc, owned = [], 0, []
    for p in pid_files(run):
        rec = read_pid(p)
        if rec is None:
            p.unlink(missing_ok=True)
            did.append(f"已删除无效的 pid 文件 {p.name}")
        elif not ours(*rec):
            p.unlink(missing_ok=True)
            did.append(f"已删除过期的 pid 文件 {p.name}（{rec[0]} 已退出或不是 harness 的进程，没发信号）")
        else:
            owned.append((p, *rec))
    if owned:
        m = ppid_map()
        me = ancestors(os.getpid(), m) | {os.getpid()}   # 从调度器里跑的 down：不停自己和上级
        groups = []
        for p, pid, start in owned:
            if pid in me:
                did.append(f"{pid}（{p.name}）是本命令的上级进程，未停止")
                rc = 1
                continue
            procs = [(pid, start)] + [(k, starttime(k)) for k in descendants(pid, m) if k not in me and k > 1]
            for k, _ in procs:   # 只发给这些 pid：不发给进程组，不发 SIGKILL
                try:
                    os.kill(k, signal.SIGTERM)
                except OSError:
                    pass
            groups.append((p, procs))
        deadline = time.time() + 5
        while time.time() < deadline and any(same(k, st) for _, procs in groups for k, st in procs):
            time.sleep(0.1)
        for p, procs in groups:
            (pid, start), kids = procs[0], procs[1:]
            left = [k for k, st in kids if same(k, st)]
            if same(pid, start):
                did.append(f"{pid}（{p.name}）收到 SIGTERM 后未停止，保留 pid 文件；需要的话手动 kill {pid}")
                rc = 1
            else:
                p.unlink(missing_ok=True)
                did.append(f"已停止 {pid}（{p.name}）" + (f"，连同 {len(kids)} 个子进程" if kids else ""))
            if left:
                did.append(f"{pid} 的子进程 {' '.join(map(str, left))} 未停止")
                rc = 1
    with cron_lock():
        lines = cron_read()
        mine = [l for l in lines or [] if is_mine(l, main)]
        if mine:
            if cron_write([l for l in lines if l not in mine]):
                did += [f"已移除定时任务：{l}" for l in mine]
            else:
                did.append("移除定时任务失败：crontab 写入出错")
                rc = 1
    if prune_audit:
        gone = lib.prune_audit(main)
        did.append(f"已删除 {len(gone)} 个超过 {lib.audit_keep_days()} 天的审计日志" if gone else "没有过期的审计日志")
    print("\n".join(did) if did else "没有要停的")
    return rc


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
    return down(_repo_arg(argv), "--prune-audit" in argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], str(PKG)))
