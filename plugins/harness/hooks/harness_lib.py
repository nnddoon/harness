#!/usr/bin/env python3
"""Shared helpers for the agentic loop harness (stdlib only).

CLI (used by skills' !`...` context injection and by scripts/):
  harness_lib.py where                 # repo / worktree / branch / task summary
  harness_lib.py current-path          # path of current task card
  harness_lib.py context <align|run|close|groom>
  harness_lib.py next-ready            # first ready task whose deps are done/review
  harness_lib.py set-status T-xxx <status> [--owner X] [--backlog-only]   # backlog line (+ task card)
  harness_lib.py card-status T-xxx [--root DIR]
  harness_lib.py sync-merged           # review -> done for branches merged into main
  harness_lib.py goal T-xxx [--note X] [--strict] # the /goal prompt used for unattended runs
  harness_lib.py merge-pr T-xxx       # read-only: the PR the scheduler recorded for G-Txxx-merge (exit 1 = none)
  harness_lib.py decide T-xxx [--after T-yyy] [--context PCT]   # same|new conversation + reason
  harness_lib.py pick-batch N [--skip ids]                       # ready tasks safe to run in parallel
  harness_lib.py board                 # global state for the control tower
  harness_lib.py status                # write .harness/STATUS.md for teammates
  harness_lib.py waves                 # dependency layers of the remaining work
  harness_lib.py lessons T-xxx <wt>    # copy a card's 教训 into .claude/rules/lessons.md
  harness_lib.py morning [--log f] [--branch b]   # the <=20-line morning report
  harness_lib.py critics <risk> [verify|spec]     # angles for adversarial critics (one per line)
  harness_lib.py review-load           # minutes<TAB>items waiting for the human
  harness_lib.py metrics [--days 7]    # idea→merge median hours, interruptions/day, hand edits to config
  harness_lib.py trust [--apply KIND]  # trust ladder: how often your choice matched the recommendation
  harness_lib.py gate-policy KIND      # auto | ask
  harness_lib.py apply-gate G-xxx      # human-only: apply an approved gate's then_policy / then_rules
  harness_lib.py answer G-xxx <LETTER> [note]   # human-only: answer a gate (exit 0 recorded, 1 already, 2 unknown)
  harness_lib.py migrate-answers       # human-only: import v0.1 answers from gate cards into the answers store
  harness_lib.py show G-xxx            # what a gate means (from its control-plane snapshot) and its answer
  harness_lib.py sandbox-check        # ok | one-line fix (exit 3) — can the Claude Code sandbox run here?
  harness_lib.py control-diff <base> <branch> [--root DIR]   # control paths the branch changed (exit 1 = hit, 2 = error)
  harness_lib.py sandbox-run [--root DIR] [--export COMMIT] -- <cmd…> | --check  # run cmd inside srt, no credentials (exit 3 = no srt)
  harness_lib.py task-branch T-xxx     # the task's branch per the main checkout's card (must be task/T-xxx-…; exit 1 otherwise)
  harness_lib.py default-branch [--root DIR]   # origin/HEAD → init.defaultBranch → main → master (exit 2 = none)
  harness_lib.py launch [--strict] [--role task|plan] [--task T-xxx] [--root DIR] [--print-settings] -- <claude args>
"""
from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path

TASK_RE = re.compile(r"(T-\d{3,})")
BACKLOG_LINE_RE = re.compile(
    r"^- (?P<id>T-\d+) \| (?P<status>[a-z_]+) \| (?P<prio>P\d) \| (?P<title>.*?) \| "
    r"deps: (?P<deps>[^|]*?) \| auto_ok: (?P<auto>yes|no) \| owner: (?P<owner>.*)$"
)
DONE_LIKE = {"done"}  # deps must be merged: new worktrees branch from main


def done_like() -> set:
    """In night/integration mode a dependency is satisfied once it is on the integration branch,
    because dependents then branch from that branch (HARNESS_INTEGRATION=<branch>)."""
    return DONE_LIKE | ({"integrated"} if os.environ.get("HARNESS_INTEGRATION") else set())


# ---------------------------------------------------------------- git helpers
def _git(args: list[str], cwd: str | os.PathLike) -> str:
    try:
        out = subprocess.run(
            ["git", *args], cwd=str(cwd), capture_output=True, text=True, timeout=10
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


def repo_root(cwd: str | os.PathLike) -> Path | None:
    top = _git(["rev-parse", "--show-toplevel"], cwd)
    return Path(top) if top else None


def current_branch(cwd: str | os.PathLike) -> str:
    return _git(["branch", "--show-current"], cwd)


def is_linked_worktree(cwd: str | os.PathLike) -> bool:
    gd = _git(["rev-parse", "--absolute-git-dir"], cwd)
    cd = _git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd)
    return bool(gd and cd and os.path.realpath(gd) != os.path.realpath(cd))


def main_checkout(cwd: str | os.PathLike) -> Path | None:
    cd = _git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd)
    return Path(cd).parent if cd else None


# ---------------------------------------------------------------- task cards
def task_id_for(root: Path, branch: str) -> str | None:
    m = TASK_RE.search(branch or "")
    if m:
        return m.group(1)
    cur = root / ".harness" / "current"
    if cur.exists():
        m = TASK_RE.search(cur.read_text(encoding="utf-8"))
        if m:
            return m.group(1)
    return None


def task_card_path(root: Path, task_id: str) -> Path | None:
    hits = sorted(glob.glob(str(root / ".harness" / "tasks" / f"{task_id}*.md")))
    return Path(hits[0]) if hits else None


def _parse_value(v: str):
    v = re.sub(r"\s+#.*$", "", v).strip()
    if v.startswith("[") and v.endswith("]"):
        inner = v[1:-1].strip()
        return [x.strip().strip("'\"") for x in inner.split(",") if x.strip()] if inner else []
    return v.strip("'\"")


def read_frontmatter(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end == -1:
        return {}
    data = {}
    for line in text[3:end].splitlines():
        if ":" in line and not line.lstrip().startswith("#"):
            k, v = line.split(":", 1)
            data[k.strip()] = _parse_value(v)
    return data


def set_frontmatter_field(path: Path, key: str, value: str) -> None:
    text = path.read_text(encoding="utf-8")
    new, n = re.subn(
        rf"^({re.escape(key)}:)[ \t]*([^#\n]*?)([ \t]*#.*)?$",
        lambda m: f"{m.group(1)} {value}" + ((m.group(3) if m.group(3)[:1] in " \t" else "  " + m.group(3))
                                             if m.group(3) else ""),
        text, count=1, flags=re.M,
    )
    if n:
        path.write_text(new, encoding="utf-8")


def ensure_frontmatter_field(path: Path, key: str, value: str) -> None:
    """Set key if present, otherwise insert it just before the closing '---'."""
    text = path.read_text(encoding="utf-8")
    if re.search(rf"^{re.escape(key)}:", text, re.M):
        set_frontmatter_field(path, key, value)
        return
    end = text.find("\n---", 3)
    if text.startswith("---") and end != -1:
        path.write_text(text[:end] + f"\n{key}: {value}" + text[end:], encoding="utf-8")


def worktrees(cwd) -> list:
    """[(path, branch)] for every worktree of the repo, main checkout first."""
    out, path = [], None
    for line in _git(["worktree", "list", "--porcelain"], cwd).splitlines():
        if line.startswith("worktree "):
            path = Path(line[9:])
        elif line.startswith("branch ") and path:
            out.append((path, line[7:].replace("refs/heads/", "")))
            path = None
        elif line == "detached" and path:
            out.append((path, ""))
            path = None
    return out


def merge_gid(tid: str) -> str:
    """合并门卡号：T-050 -> G-T050-merge。"""
    return f"G-{tid.replace('-', '')}-merge"


def goal_prompt(tid: str, note: str = "", strict: bool = False) -> str:
    pre = f"{note}\n" if note else ""
    text = (f"/goal {pre}按 /task-run 流程完成 {tid}，然后执行 /task-close {tid}（无人值守：不要提问，第 6 步选默认）。"
            f"完成条件：.harness/tasks/{tid}*.md 的 status 为 review，交接包 .harness/handoffs/{tid}.md 已写，"
            f"任务卡第 10 节 verifier 结论为 PASS；或 status 为 waiting_human 或 blocked 且「7. 当前进展」写明原因与需要的人工门；"
            f"或已进行 40 轮。约束：只修改 allowed_paths 内的文件，不删除或跳过测试，不合并、不部署。")
    if strict:  # S-002 #11：GitHub 写操作只在控制面
        text += (f"strict 模式（HARNESS_STRICT=1）：不推送分支、不开 PR、不调用 gh；/task-close 第 4 步只提交到本地分支，"
                 f"写交接包和合并门卡草稿 .harness/gates/{merge_gid(tid)}.md（kind: irreversible，pr: 留空），"
                 "推送与开 PR 由调度器完成。")
    return text


def section(text: str, heading_prefix: str) -> str:
    """Return body of the markdown '## <prefix>...' section."""
    m = re.search(rf"^## {re.escape(heading_prefix)}.*?$(.*?)(?=^## |\Z)", text, re.M | re.S)
    return m.group(1) if m else ""


def unchecked_items(card_text: str) -> list[str]:
    items = []
    for sec in ("4.", "5."):
        body = section(card_text, sec)
        if sec == "5.":  # only machine acceptance (A); B is handled by gates
            body = body.split("**B.", 1)[0]
        items += [l.strip() for l in body.splitlines() if l.strip().startswith("- [ ]")]
    return items


# ---------------------------------------------------------------- locks / globs
def glob_to_regex(pat: str) -> re.Pattern:
    pat = pat.strip()
    if pat.endswith("/"):
        pat += "**"
    i, out = 0, ""
    while i < len(pat):
        c = pat[i]
        if pat.startswith("**/", i):
            out += r"(?:.*/)?"
            i += 3
        elif pat.startswith("**", i):
            out += r".*"
            i += 2
        elif c == "*":
            out += r"[^/]*"
            i += 1
        elif c == "?":
            out += r"[^/]"
            i += 1
        else:
            out += re.escape(c)
            i += 1
    return re.compile(rf"^{out}$")


def _norm(p: str) -> str:
    p = p.strip()
    return p[2:] if p.startswith("./") else p


def matches_any(rel: str, patterns: list[str]) -> str | None:
    rel = _norm(rel)
    for p in patterns:
        if _norm(p) and glob_to_regex(_norm(p)).match(rel):
            return p
    return None


def read_locks(root: Path) -> list[tuple[str, str]]:
    f = root / ".harness" / "locks.txt"
    if not f.exists():
        return []
    out = []
    for line in f.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        pat, _, why = s.partition("#")
        out.append((pat.strip(), why.strip()))
    return out


# ---------------------------------------------------------------- gates
def gates(root: Path) -> list[dict]:
    res = []
    for p in sorted(glob.glob(str(root / ".harness" / "gates" / "G-*.md"))):
        fm = read_frontmatter(Path(p))
        fm["_path"] = p
        res.append(fm)
    return res


def gate_id(g: dict) -> str:
    """A gate is named by its file (G-xxx.md); the card's own `id:` line is Claude-writable and not trusted."""
    return Path(g["_path"]).stem if g.get("_path") else str(g.get("id") or "")


def task_of_gid(gid: str) -> str:
    """G-T123-4 -> T-123; anything else (G-GROOM-…) -> ''. The card's `task:` line is never trusted."""
    m = re.match(r"G-T(\d{3,})-", str(gid or ""))
    return f"T-{m.group(1)}" if m else ""


def _owned(main: Path, g: dict, wts: list) -> bool:
    """True when this card file is the one find_gate_card resolves (planted copies elsewhere are ignored)."""
    p = find_gate_card(main, gate_id(g), wts)
    return bool(p) and p.resolve() == Path(g["_path"]).resolve()


def approved_gate(root: Path, task_id: str, kind: str) -> dict | None:
    """A gate card still present under `root` whose answer in the store is A, with task/kind from the snapshot
    taken when the control plane first saw the gate (T-010: Claude editing the card changes nothing)."""
    main = store_main(root)
    wts = worktrees(main)
    for g in gates(root):
        a = read_answer(main, gate_id(g))
        if (a and not a.get("_bad") and a.get("task") == task_id and a.get("kind") == kind
                and a.get("letter") == "A" and _owned(main, g, wts)):
            return dict(g, _answer=a, _meta=read_meta(main, gate_id(g)) or {})
    return None


def open_gates(root: Path, task_id: str | None = None) -> list[dict]:
    """Still open = no answer in the store (the card's `status:` is only a mirror). The task comes from the gate
    number; a store that cannot be read gives 'unknown', which is neither open nor answered."""
    main = store_main(root)
    wts = worktrees(main)
    return [g for g in gates(root)
            if (task_id is None or task_of_gid(gate_id(g)) == task_id)
            and gate_state(main, gate_id(g)) == "open" and _owned(main, g, wts)]


# ---------------------------------------------------------------- answers store (S-002 T-010)
# Answers live outside the repo: state_dir(main)/answers/<GID>.json, written only by the control plane
# (terminal `answer`, the dashboard, gate-sync, the publish hook's auto decisions). First answer wins.
# What a gate means (task, kind, options, then…, unlock paths) is frozen in <GID>.meta.json the first time the
# control plane sees the card; later edits to the card change nothing.
GID_RE = re.compile(r"G-[A-Za-z0-9]+-[A-Za-z0-9-]+")  # always fullmatch
VIAS = ("终端", "看板", "GitHub", "对话", "Telegram", "auto", "迁移")
APPROVAL_KINDS = {"irreversible", "unlock", "external"}
OPT_LINE = re.compile(r"^\s*[-*]\s+\*{0,2}([A-Z])((?:（|\()推荐(?:）|\)))?\*{0,2}\s*[:：]\s*(.*)$")
_MAIN_CACHE: dict = {}


def valid_gid(gid) -> bool:
    return isinstance(gid, str) and GID_RE.fullmatch(gid) is not None


def store_main(path) -> Path:
    """The main checkout whose store a path belongs to (a worktree maps to its main checkout)."""
    key = str(path)
    if key not in _MAIN_CACHE:
        m = main_checkout(path) if Path(path).is_dir() else None
        _MAIN_CACHE[key] = (m or Path(path)).resolve()
    return _MAIN_CACHE[key]


def answers_dir(main: Path, create: bool = False) -> Path:
    d = state_dir(store_main(main)) / "answers"
    if create and not d.is_dir():
        d.mkdir(parents=True, exist_ok=True)
        for p in (d.parent, d):
            os.chmod(p, 0o700)
    return d


def one_line(text) -> str:
    """Everything splitlines() splits on becomes a space and other control characters go, so a note can never
    forge a frontmatter field or a decisions.md line."""
    flat = " ".join(str(text or "").splitlines())
    return "".join(ch for ch in flat if ch == " " or ch.isprintable()).strip()


def _now() -> str:
    import datetime as _dt
    return _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds")


def _create_json(path: Path, data: dict) -> bool:
    """Atomically create `path` with complete content; False when it already exists (first writer wins)."""
    import tempfile
    payload = json.dumps(data, ensure_ascii=False, sort_keys=True).encode("utf-8")
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        try:
            os.link(tmp, path)  # atomic, never overwrites, and readers never see a half-written file
            return True
        except FileExistsError:
            return False
        except OSError:  # filesystem without hard links: fall back to O_EXCL
            try:
                fd2 = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                return False
            with os.fdopen(fd2, "wb") as f:
                f.write(payload)
            return True
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def _replace_json(path: Path, data: dict) -> None:
    import tempfile
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(path.parent))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, sort_keys=True)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def _read_json(path: Path):
    """-> dict | None (missing) | {} (unreadable content). OSError other than 'missing' propagates."""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    try:
        d = json.loads(text)
    except ValueError:
        return {}
    return d if isinstance(d, dict) else {}


def _marker(main: Path, gid: str, suffix: str) -> Path:
    return answers_dir(main) / f"{gid}{suffix}"


def _present(p: Path) -> bool:
    try:
        return p.exists()
    except OSError:
        return False


def find_gate_card(main: Path, gid: str, wts: list | None = None) -> Path | None:
    """The card <gid>.md: in the worktree of the task the gate number names (branch task/T-xxx-* or
    worktree-T-xxx), else in the main checkout. Same-named cards anywhere else are ignored."""
    if not valid_gid(gid):
        return None
    main = store_main(main)
    tid = task_of_gid(gid)
    roots = []
    if tid:
        for path, br in (worktrees(main) if wts is None else wts):
            if re.fullmatch(rf"task/{tid}(-.*)?|worktree-{tid}", br or ""):
                roots.append(Path(path))
    roots.append(main)
    for r in roots:
        p = r / ".harness" / "gates" / f"{gid}.md"
        if p.is_file():
            return p
    return None


def _card_body(card: Path) -> str:
    text = card.read_text(encoding="utf-8")
    end = text.find("\n---", 3) if text.startswith("---") else -1
    return text[end + 4:] if end != -1 else text


def _as_list(v) -> list:
    return [str(x) for x in (v if isinstance(v, list) else [v] if v else [])]


def card_meaning(card: Path, gid: str) -> dict:
    """What the card says right now: kind, title, options (compared with the snapshot before a terminal answer)."""
    fm, body = read_frontmatter(card), _card_body(card)
    m = re.search(r"^#\s+(.+)$", body, re.M)
    title = one_line(re.sub(rf"^{re.escape(gid)}\s*", "", m.group(1)).strip()) if m else gid
    opts, seen = [], set()
    for ln in body.splitlines():
        om = OPT_LINE.match(ln)
        if om and om.group(1) not in seen:
            seen.add(om.group(1))
            opts.append({"letter": om.group(1), "text": one_line(om.group(3))})
    return {"kind": str(fm.get("kind") or "").strip(), "title": title, "options": opts}


def meaning_diff(meta: dict, card: Path) -> list:
    """Lines describing how the card's kind / title / options differ from the snapshot ([] = same)."""
    now = card_meaning(card, meta.get("gid", card.stem))
    out = []
    for k, label in (("kind", "类别"), ("title", "问题")):
        if str(now[k]) != str(meta.get(k, "")):
            out.append(f"{label}：快照「{meta.get(k, '')}」 ≠ 门卡现在「{now[k]}」")
    old = {o["letter"]: o.get("text", "") for o in meta.get("options") or []}
    new = {o["letter"]: o.get("text", "") for o in now["options"]}
    for L in sorted(set(old) | set(new)):
        if old.get(L) != new.get(L):
            out.append(f"选项 {L}：快照「{old.get(L, '（无）')}」 ≠ 门卡现在「{new.get(L, '（无）')}」")
    return out


def _sha256(path: Path) -> str:
    import hashlib
    return hashlib.sha256(path.read_bytes()).hexdigest()


def card_changed(meta: dict, card: Path) -> bool:
    try:
        return bool(meta.get("card_sha256")) and _sha256(card) != meta["card_sha256"]
    except OSError:
        return True


def retire_snapshot(main: Path, gid: str) -> bool:
    """A snapshot is retired only when the gate has no answer and no control-plane PR and its card no longer
    resolves (seen missing). Then the meta, the issue mapping and the publish claim go; a card that reappears is a
    new gate."""
    main = store_main(main)
    if not valid_gid(gid) or find_gate_card(main, gid) is not None:
        return False
    if gate_state(main, gid) != "open" or _present(_marker(main, gid, ".pr.json")):
        return False
    gone = False
    for suffix in (".meta.json", ".issue.json", ".pubclaim.json"):
        try:
            _marker(main, gid, suffix).unlink()
            gone = True
        except FileNotFoundError:
            pass
        except OSError:
            return False
    return gone


def retire_vanished(main: Path) -> list:
    """Every unanswered snapshot whose card has vanished (dashboard, board and gate-sync call this). -> [gid]"""
    out = []
    try:
        files = sorted(answers_dir(main).glob("G-*.meta.json"))
    except OSError:
        return out
    for p in files:
        gid = p.name[:-len(".meta.json")]
        if valid_gid(gid) and retire_snapshot(main, gid):
            out.append(gid)
    return out


def snapshot_meta(main: Path, gid: str) -> dict | None:
    """First sight of a gate by the control plane: freeze what it means (O_EXCL). Already there -> as is
    (edits or a replaced file never change it). A card seen missing while unanswered retires its snapshot."""
    if not valid_gid(gid):
        return None
    main = store_main(main)
    try:
        card = find_gate_card(main, gid)
        if not card:
            retire_snapshot(main, gid)
            return None
        have = read_meta(main, gid)
        if have is not None:
            return have
        fm = read_frontmatter(card)
        cm = card_meaning(card, gid)
        tid, kind, title, opts = task_of_gid(gid), cm["kind"], cm["title"], cm["options"]
        paths = []
        if kind == "unlock" and tid:
            tc = task_card_path(card.parents[2], tid) or task_card_path(task_location(main, tid), tid)
            paths = _as_list(read_frontmatter(tc).get("unlock")) if tc else []
        then = str(fm.get("then") or "").strip()
        data = {"gid": gid, "task": tid, "kind": kind, "title": title, "options": opts,
                "recommended": _letter(fm.get("recommended")) or "A", "paths": paths,
                "then": then if then == "ready" else "",
                "then_tasks": [t for t in _as_list(fm.get("then_tasks")) if TASK_RE.fullmatch(t)],
                "then_policy": one_line(fm.get("then_policy") or ""),
                "then_rules": [one_line(x) for x in _as_list(fm.get("then_rules")) if one_line(x)],
                "card_sha256": _sha256(card), "at": _now()}
        _create_json(answers_dir(main, create=True) / f"{gid}.meta.json", data)
        return read_meta(main, gid)
    except OSError:
        return None


def read_meta(main: Path, gid: str) -> dict | None:
    if not valid_gid(gid):
        return None
    try:
        d = _read_json(_marker(main, gid, ".meta.json"))
    except OSError:
        return None
    return d if d and d.get("gid") == gid else None


def meta_letters(meta: dict) -> list:
    """Option letters frozen in the meta; A/B when the card had none."""
    return [o["letter"] for o in meta.get("options") or []] or ["A", "B"]


def meta_option(meta: dict, letter: str) -> str:
    return next((o.get("text", "") for o in meta.get("options") or [] if o.get("letter") == letter), "")


def _answer_raw(main: Path, gid: str) -> tuple:
    """-> ('open', None) | ('answered', dict) | ('unknown', None). A corrupt entry is answered but `_bad`."""
    try:
        d = _read_json(answers_dir(main) / f"{gid}.json")
    except OSError:
        return "unknown", None
    if d is None:
        return "open", None
    if d.get("gid") != gid or not re.fullmatch(r"[A-Z]", str(d.get("letter") or "")):
        return "answered", {"gid": gid, "letter": "", "approved": False, "task": "", "kind": "", "paths": [],
                            "via": "", "note": "", "_bad": "corrupt"}
    return "answered", d


def gate_state(main: Path, gid: str) -> str:
    """'open' | 'answered' | 'unknown' (the store cannot be read: neither open nor answered)."""
    if not valid_gid(gid):
        return "unknown"
    return _answer_raw(store_main(main), gid)[0]


def read_answer(main: Path, gid: str) -> dict | None:
    """The stored answer; None when there is none. Unreadable store or corrupt entry -> a dict with `_bad`
    (never an approval)."""
    if not valid_gid(gid):
        return None
    state, d = _answer_raw(store_main(main), gid)
    if state == "unknown":
        return {"gid": gid, "letter": "", "approved": False, "task": "", "kind": "", "paths": [], "via": "",
                "note": "", "_bad": "unknown"}
    return d


def store_answers(main: Path) -> list:
    """[(gid, answer)] for every readable, well-formed answer in the store."""
    out = []
    try:
        files = sorted(answers_dir(main).glob("G-*.json"))
    except OSError:
        return out
    for p in files:
        if valid_gid(p.stem):
            a = read_answer(main, p.stem)
            if a and not a.get("_bad"):
                out.append((p.stem, a))
    return out


def record_answer(main: Path, gid: str, letter: str, note: str = "", via: str = "终端") -> bool:
    """The only way an answer enters the store. task / kind / paths come from the gate's meta snapshot
    (taken now if this is the first sight); approved ⇔ letter A."""
    if not valid_gid(gid) or via not in VIAS:
        return False
    letter = str(letter or "").strip().upper()
    if not re.fullmatch(r"[A-Z]", letter):
        return False
    main = store_main(main)
    if not find_gate_card(main, gid):
        return False
    meta = snapshot_meta(main, gid)
    if not meta:
        return False
    data = {"gid": gid, "letter": letter, "note": one_line(note)[:500], "via": via, "at": _now(),
            "approved": letter == "A", "task": meta.get("task", ""), "kind": meta.get("kind", ""),
            "paths": list(meta.get("paths") or [])}
    return _create_json(answers_dir(main, create=True) / f"{gid}.json", data)


def record_pr(main: Path, gid: str, number: int, replace: bool = False) -> bool:
    """Control plane only: the PR it opened for this gate. Merged = A, closed = B. First record wins, except that
    the scheduler replaces a mapping it found forged or closed (replace=True, T-011)."""
    if not valid_gid(gid) or not isinstance(number, int) or isinstance(number, bool) or number <= 0:
        return False
    path = answers_dir(main, create=True) / f"{gid}.pr.json"
    data = {"gid": gid, "pr": number, "at": _now()}
    if replace:
        _replace_json(path, data)
        return True
    return _create_json(path, data)


def record_merge_pr(main: Path, tid: str, number: int, replace: bool = False) -> bool:
    """Control plane, after it pushed the task branch and opened PR #number (T-011): map the merge gate
    G-<T无连字符>-merge to it. No draft card anywhere -> write one (kind irreversible) in the main checkout, atomically
    (temp file + os.replace: a symlink in its place is replaced, never followed). No CLI writes this."""
    import tempfile
    gid = merge_gid(tid)
    if not TASK_RE.fullmatch(tid) or not valid_gid(gid):
        return False
    main = store_main(main)
    d = main / ".harness" / "gates"
    card = find_gate_card(main, gid)
    target = d / f"{gid}.md"
    if card is None or (card == target and target.is_symlink()):
        if not target.is_file() or target.is_symlink():
            d.mkdir(parents=True, exist_ok=True)
            if d.is_symlink() or (main / ".harness").is_symlink():
                return False
            text = (f"---\nid: {gid}\ntask: {tid}\nkind: irreversible\nstatus: open\ncreated: {_now()[:10]}\n"
                    "urgency: normal\nrecommended: A\ndecided_by: human\nreview_minutes: 10\n"
                    "default_if_no_answer: 不合并；任务保持 review\nanswer:\napprove_options: [A]\nthen:\npr:\nissue:\n---\n\n"
                    f"# {gid} 合并 {tid} 到 main？\n\n"
                    f"**为什么需要你：** 合并进 main 不可撤回，PR #{number} 由调度器开出。\n\n"
                    f"## 选项\n- **A（推荐）**：合并 PR #{number} — 后果：任务标记 done\n"
                    "- **B**：关闭 PR — 后果：不合并，任务保持 review\n\n"
                    "合并这个 PR 即视为批准，关闭即视为拒绝。\n")
            fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(d))
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    f.write(text)
                os.replace(tmp, target)
            except BaseException:
                if os.path.exists(tmp):
                    os.unlink(tmp)
                raise
    snapshot_meta(main, gid)
    return record_pr(main, gid, number, replace=replace)


def read_pr(main: Path, gid: str) -> int | None:
    if not valid_gid(gid):
        return None
    try:
        d = _read_json(_marker(main, gid, ".pr.json")) or {}
    except OSError:
        return None
    return d.get("pr") if d.get("gid") == gid and isinstance(d.get("pr"), int) else None


def pr_gates(main: Path) -> list:
    out = []
    try:
        files = sorted(answers_dir(main).glob("G-*.pr.json"))
    except OSError:
        return out
    for p in files:
        gid = p.name[:-len(".pr.json")]
        n = read_pr(main, gid)
        if n:
            out.append((gid, n))
    return out


def record_issue(main: Path, gid: str, number: int) -> bool:
    """Control plane only, at publish time: which issue belongs to which gate (never parsed from issue bodies)."""
    if not valid_gid(gid) or not isinstance(number, int) or isinstance(number, bool) or number <= 0:
        return False
    _replace_json(answers_dir(main, create=True) / f"{gid}.issue.json", {"gid": gid, "issue": number})
    return True


def read_issue(main: Path, gid: str) -> int | None:
    if not valid_gid(gid):
        return None
    try:
        d = _read_json(_marker(main, gid, ".issue.json")) or {}
    except OSError:
        return None
    return d.get("issue") if d.get("gid") == gid and isinstance(d.get("issue"), int) else None


def issue_map(main: Path) -> dict:
    """{issue number: gid} from the store."""
    out = {}
    try:
        files = sorted(answers_dir(main).glob("G-*.issue.json"))
    except OSError:
        return out
    for p in files:
        gid = p.name[:-len(".issue.json")]
        n = read_issue(main, gid)
        if n:
            out[n] = gid
    return out


def take_resumes(main: Path) -> list:
    """[(gid, task)] queued by answers that unblocked a task; each marker is handed out once."""
    out = []
    d = answers_dir(main)
    try:
        files = sorted(d.glob("G-*.resume"))
    except OSError:
        return out
    for p in files:
        gid = p.name[:-len(".resume")]
        try:
            tid = p.read_text(encoding="utf-8").strip()
            os.replace(p, d / f"{gid}.resumed")
        except OSError:
            continue  # another sync took it
        if valid_gid(gid) and TASK_RE.fullmatch(tid):
            out.append((gid, tid))
    return out


def _log_decision(root: Path, gid: str, status: str, answer: str, via: str, detail: str) -> None:
    import datetime as _dt
    dec = root / ".harness" / "decisions.md"
    dec.parent.mkdir(parents=True, exist_ok=True)
    with dec.open("a+", encoding="utf-8") as f:
        try:
            import fcntl
            fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        except (ImportError, OSError):
            pass
        f.seek(0)
        n = len(re.findall(r"^- D-\d+", f.read(), re.M)) + 1
        f.seek(0, 2)
        f.write(f"- D-{n:03d} | {_dt.date.today().isoformat()} | {gid} | {status}: {one_line(answer)[:200]} "
                f"| via {via}{(' ' + one_line(detail)) if detail else ''}\n")


def _claim_settle(main: Path, gid: str, takeover_stale: bool = False) -> bool:
    """O_EXCL <GID>.settling: only one settle runs. gate-sync may take over a claim older than
    HARNESS_SETTLE_STALE seconds (default 600) that never reached .settled."""
    claim = _marker(main, gid, ".settling")
    try:
        os.close(os.open(str(claim), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        return True
    except FileExistsError:
        pass
    except OSError:
        return False
    if not takeover_stale:
        return False
    import time
    try:
        stale = float(os.environ.get("HARNESS_SETTLE_STALE", "600"))
    except ValueError:
        stale = 600.0
    try:
        if time.time() - claim.stat().st_mtime < stale:
            return False
        old = claim.with_name(f"{claim.name}.stale-{os.getpid()}")
        os.replace(claim, old)  # only one taker gets to move it
        os.unlink(old)
        os.close(os.open(str(claim), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        return True
    except OSError:
        return False


def settle_answer(main: Path, gid: str, detail: str = "", takeover_stale: bool = False) -> tuple:
    """After a store write: mirror it onto the card and decisions.md, apply `then: ready` / policies, unblock the
    task and queue its resume, then mark <GID>.settled. Everything comes from the store entry and the meta
    snapshot, never from the card. Replays are no-ops. -> (status, task_unblocked_or_None)"""
    main = store_main(main)
    if not valid_gid(gid) or _present(_marker(main, gid, ".settled")):
        return "", None
    a, card, meta = read_answer(main, gid), find_gate_card(main, gid), read_meta(main, gid)
    if not a or a.get("_bad") or not card or not meta:
        return "", None
    if not _claim_settle(main, gid, takeover_stale) or _present(_marker(main, gid, ".settled")):
        return "", None  # someone else is settling (or just did)
    letter, via, tid, kind = a["letter"], a.get("via", ""), meta.get("task", ""), meta.get("kind", "")
    approved = letter == "A"
    status = ("approved" if approved else "rejected") if kind in APPROVAL_KINDS else "answered"
    opt = meta_option(meta, letter)
    if "<" in opt:  # template placeholder, not a real option
        opt = ""
    answer = one_line(letter + (f"（{opt}）" if opt else "") + (f" — {a['note']}" if a.get("note") else ""))[:300]
    ensure_frontmatter_field(card, "status", status)
    ensure_frontmatter_field(card, "answer", answer)
    ensure_frontmatter_field(card, "decided_by", "auto" if via == "auto" else "human")
    root = card.parents[2]
    _log_decision(root, gid, status, answer, via, detail)
    resume = None
    human = via in ("终端", "GitHub", "看板", "对话", "Telegram")
    if approved and via in ("终端", "GitHub"):
        # a human answering outside Claude's session: apply policy/rule changes Claude itself may not make
        if meta.get("then_policy"):
            apply_policy(main, meta["then_policy"])
        if meta.get("then_rules"):
            apply_rules(main, meta["then_rules"], gid)
    if meta.get("then") == "ready" and approved and human:
        # a "confirm this task card / spec" gate: approving makes the task(s) ready (auto never does)
        for t in meta.get("then_tasks") or ([tid] if tid else []):
            c = task_card_path(root, t)
            if c:
                set_frontmatter_field(c, "status", "ready")
            set_backlog_status(root, t, "ready")
    else:
        tcard = task_card_path(root, tid) if tid else None
        if tcard and read_frontmatter(tcard).get("status") == "waiting_human" and not open_gates(root, tid):
            set_frontmatter_field(tcard, "status", "in_progress")
            _marker(main, gid, ".resume").write_text(tid, encoding="utf-8")
            resume = tid
    _marker(main, gid, ".settled").write_text("", encoding="utf-8")
    return status, resume


def settle_pending(main: Path) -> list:
    """Re-run settle for answers stored but never settled (crash between store write and mirror). -> [gid]"""
    out = []
    for gid, _a in store_answers(main):
        if not _present(_marker(main, gid, ".settled")):
            st, _t = settle_answer(main, gid, takeover_stale=True)
            if st:
                out.append(gid)
    return out


def answer_gate(main: Path, gid: str, letter: str, note: str = "", via: str = "终端", detail: str = "") -> tuple:
    """record_answer + settle_answer. -> (recorded, status, task_unblocked_or_None)"""
    if not record_answer(main, gid, letter, note, via):
        return False, "", None
    status, tid = settle_answer(main, gid, detail)
    return True, status, tid


def auto_answer(main: Path, gid: str) -> bool:
    """Control plane: a gate whose (snapshotted) kind the human delegated (auto-decide.txt, never NEVER_AUTO) is
    decided with the snapshotted recommendation. Records the answer and mirrors only: `then` is never applied."""
    main = store_main(main)
    if gate_state(main, gid) != "open" or not find_gate_card(main, gid):
        return False
    meta = snapshot_meta(main, gid) or {}
    kind = meta.get("kind", "")
    allowed = auto_kinds(main)
    # the snapshot decides; a later relabel on the card can only make it ask the human, never the reverse
    now = str(read_frontmatter(find_gate_card(main, gid)).get("kind") or "").strip()
    if not kind or kind in NEVER_AUTO or kind not in allowed or now in NEVER_AUTO or now not in allowed:
        return False
    return answer_gate(main, gid, meta.get("recommended") or "A", "", "auto")[0]


def approved_unlock_paths(main: Path, tid: str) -> list:
    """Paths the human unlocked for `tid`: the meta `paths` of gates with an A answer, task == tid, kind unlock."""
    out = []
    if not tid:
        return out
    main = store_main(main)
    for gid, a in store_answers(main):
        meta = read_meta(main, gid) or {}
        if (a.get("letter") == "A" and meta.get("task") == tid and meta.get("kind") == "unlock"
                and a.get("task") == tid and a.get("kind") == "unlock"):
            out += [str(x) for x in meta.get("paths") or []]
    return list(dict.fromkeys(out))


def unlocked_paths(main: Path, tid: str) -> list:
    """Control paths the human unlocked for `tid` (strict launcher): exact CONTROL_PATHS entries only."""
    return [p for p in approved_unlock_paths(main, tid) if p in CONTROL_PATHS]


def migrate_answers(main: Path) -> tuple:
    """Import v0.1 answers (cards approved/rejected/answered with an answer). Approval kinds take the letter from
    the v0.1 status (approved -> A, rejected -> B); never imports `pr:` or `issue:`, never touches cards or
    decisions.md, never overwrites. Imported answers are marked settled. -> (answers imported, [gids])"""
    main = store_main(main)
    wts = worktrees(main)
    done = []
    seen = set()
    for path, _br in reversed(wts or [(main, "")]):
        for g in gates(Path(path)):
            gid = gate_id(g)
            if gid in seen or not valid_gid(gid) or not _owned(main, g, wts):
                continue
            seen.add(gid)
            if gate_state(main, gid) != "open":
                continue
            st, ans = str(g.get("status") or ""), str(g.get("answer") or "").strip()
            if st not in ("approved", "rejected", "answered") or not ans:
                continue
            meta = snapshot_meta(main, gid) or {}
            if meta.get("kind") in APPROVAL_KINDS:
                letter = "A" if st == "approved" else "B" if st == "rejected" else ""
            else:
                letter = _letter(ans)
            if letter and record_answer(main, gid, letter, ans, "迁移"):
                _marker(main, gid, ".settled").write_text("", encoding="utf-8")
                done.append(gid)
    return len(done), done


def gate_show(main: Path, gid: str) -> str | None:
    meta = snapshot_meta(main, gid)
    if not meta:
        return None
    a = read_answer(main, gid)
    lines = [f"{gid} {meta.get('title', '')}", f"kind: {meta.get('kind', '')}", f"task: {meta.get('task', '')}",
             f"then: {meta.get('then', '')}", f"paths: {', '.join(meta.get('paths') or []) or '-'}",
             f"recommended: {meta.get('recommended', '')}"]
    lines += [f"- {o['letter']}：{o.get('text', '')}" for o in meta.get("options") or []]
    card = find_gate_card(main, gid)
    if card and card_changed(meta, card):
        lines.append("注意：卡片在快照后改过；以上是控制面记下的含义（快照），改动不生效。")
    st = gate_state(main, gid)
    lines.append("答复：" + ("还没有" if st == "open" else "状态未知（答案库读不了）" if st == "unknown"
                            else f"{a.get('letter') or '?'}（via {a.get('via') or '?'}）"))
    return "\n".join(lines)


# ---------------------------------------------------------------- where the library lives
def lib_cmd(root) -> str:
    """The command to run this library in `root`: repo install (.claude/hooks) or plugin install (.harness/lib)."""
    return ("python3 .claude/hooks/harness_lib.py" if (Path(root) / ".claude/hooks/harness_lib.py").exists()
            else "python3 .harness/lib/harness_lib.py")


# ---------------------------------------------------------------- adversarial review
# Separate critic sessions try to disprove the work; a judge keeps only the criticisms that hold.
CRITIC_ANGLES = {
    "verify": ["测试测的不是需求：验收项真的被证明了吗", "边界、异常输入与并发", "漏改的调用方与回归",
               "安全、数据与密钥", "与 spec / 对外契约 / 交接包不一致"],
    "spec": ["漏掉的受影响模块或调用方", "验收证明不了需求", "范围过大、该拆或顺序不对"],
}
CRITIC_COUNT = {"verify": {"low": 1, "medium": 3, "high": 5}, "spec": {"low": 0, "medium": 2, "high": 3}}


def critic_plan(risk: str, stage: str = "verify") -> list[str]:
    """Angles for the critic sessions to run (len = how many). Empty = no adversarial review needed."""
    if os.environ.get("HARNESS_CRITICS") == "off":
        return []
    n = CRITIC_COUNT.get(stage, CRITIC_COUNT["verify"]).get(str(risk or "low"), 1)
    return CRITIC_ANGLES.get(stage, CRITIC_ANGLES["verify"])[:n]


def adversarial_done(card_text: str) -> bool:
    """True when section 13 of the task card has at least one filled review row (| 1 | 3 | ...)."""
    return any(re.match(r"^\|\s*\d+\s*\|", l.strip()) for l in section(card_text, "13.").splitlines())


# ---------------------------------------------------------------- review budget
# Human attention is the bottleneck: don't produce more than the human can review.
REVIEW_MIN = {"low": 2, "medium": 5, "high": 10}


def review_load(root: Path) -> tuple[int, int]:
    """(minutes, items) waiting for the human: open gates + finished tasks not yet merged."""
    mins = items = 0
    pr_tasks = set()
    for g in open_gates(root):
        if read_pr(root, gate_id(g)):
            pr_tasks.add(task_of_gid(gate_id(g)))
            continue
        try:
            m = int(g.get("review_minutes") or 0)
        except (TypeError, ValueError):
            m = 0
        if not m:
            txt = Path(g["_path"]).read_text(encoding="utf-8")
            mm = re.search(r"预计耗时[：:]\**\s*(\d+)", txt)
            m = int(mm.group(1)) if mm else 5
        mins += m
        items += 1
    for r in backlog_rows(root):
        if r["status"] in ("review", "integrated"):
            risk = card_fm(task_location(root, r["id"]), r["id"]).get("risk", "low")
            mins += REVIEW_MIN.get(str(risk), 2)
            items += 1
    return mins, items


# ---------------------------------------------------------------- trust ladder
# When Claude's recommendation keeps matching the human's choice for one kind of decision,
# suggest letting Claude decide that kind (human spot-checks). Never for irreversible/external/unlock.
NEVER_AUTO = {"irreversible", "external", "unlock"}


def _letter(ans) -> str:
    m = re.match(r"\s*([A-Za-z])\b", str(ans or ""))
    return m.group(1).upper() if m else ""


def trust_stats(root: Path) -> list[dict]:
    """Agreement between the snapshotted recommendation and the human's answer, from the answers store only
    (card answers are Claude-writable mirrors); auto decisions excluded."""
    by = {}
    main = store_main(root)
    wts = worktrees(main)
    for g in gates(root):  # gates of this checkout, answers from the store
        gid = gate_id(g)
        a = read_answer(main, gid)
        if not a or a.get("_bad") or a.get("via") in ("auto", "迁移") or not _owned(main, g, wts):
            continue
        meta = read_meta(main, gid) or {}
        rec, ans = _letter(meta.get("recommended")), a.get("letter", "")
        if not rec or not ans:
            continue
        k = str(meta.get("kind") or a.get("kind") or "?")
        d = by.setdefault(k, {"kind": k, "n": 0, "agree": 0})
        d["n"] += 1
        d["agree"] += int(rec == ans)
    min_n = int(os.environ.get("HARNESS_TRUST_MIN_N", "8"))
    min_rate = float(os.environ.get("HARNESS_TRUST_MIN_RATE", "0.9"))
    auto = auto_kinds(root)
    for d in by.values():
        d["rate"] = d["agree"] / d["n"]
        d["auto"] = d["kind"] in auto
        d["suggest"] = (d["kind"] not in NEVER_AUTO and not d["auto"]
                        and d["n"] >= min_n and d["rate"] >= min_rate)
    return sorted(by.values(), key=lambda d: (-d["n"], d["kind"]))


def auto_kinds(root: Path) -> set:
    f = root / ".harness" / "auto-decide.txt"
    if not f.exists():
        return set()
    return {l.split("#")[0].strip() for l in f.read_text(encoding="utf-8").splitlines()
            if l.split("#")[0].strip()} - NEVER_AUTO


def gate_policy(root: Path, kind: str) -> str:
    return "auto" if kind in auto_kinds(root) else "ask"


def apply_policy(root: Path, kind: str) -> bool:
    """Human-only (guard_bash blocks Claude from running it): let Claude decide `kind` from now on."""
    if kind in NEVER_AUTO or not kind:
        return False
    f = root / ".harness" / "auto-decide.txt"
    if kind in auto_kinds(root):
        return True
    head = "" if f.exists() else "# Claude 可以代你决定的门卡类别（信任阶梯）。只有你能改；irreversible/external/unlock 永远问你。\n"
    with f.open("a", encoding="utf-8") as fh:
        fh.write(head + f"{kind}  # {__import__('datetime').date.today().isoformat()} 加入\n")
    return True


def apply_rules(root: Path, lines: list, source: str) -> int:
    """Human-approved principles distilled from past decisions -> .claude/rules/lessons.md (auto-loaded)."""
    lf = root / ".claude" / "rules" / "lessons.md"
    old = lf.read_text(encoding="utf-8") if lf.exists() else "# 教训（同一个错误出现两次就记一行，所有会话自动加载）\n\n"
    add = [f"- {str(l).strip().lstrip('- ').strip()}（原则，{source}）" for l in lines
           if str(l).strip() and str(l).strip().lstrip('- ').strip() not in old]
    if not add:
        return 0
    if "## 你的原则" not in old:
        old = old.rstrip("\n") + "\n\n## 你的原则（从你过去的决定里提炼，经你确认）\n"
    lf.write_text(old.rstrip("\n") + "\n" + "\n".join(add) + "\n", encoding="utf-8")
    return len(add)


# ---------------------------------------------------------------- metrics (S-001: the three numbers we dogfood on)
CONFIG_FILES = [".harness/verify.sh", ".harness/quick-check.sh", ".harness/allow-commands.txt", ".claude/settings.json"]


def _median(xs: list):
    xs = sorted(xs)
    if not xs:
        return None
    m = len(xs) // 2
    return xs[m] if len(xs) % 2 else (xs[m - 1] + xs[m]) / 2


def metrics(root: Path, days: int = 7) -> dict:
    """idea→merge median hours, interruptions per day, hand edits to config — all read from git and .harness/."""
    import datetime as _dt
    now = _dt.datetime.now(_dt.timezone.utc)
    since = now - _dt.timedelta(days=days)
    log = [l.split("\t", 1) for l in _git(["log", "--format=%ct\t%s"], root).splitlines() if "\t" in l]
    lead = []
    for r in backlog_rows(root):
        if r["status"] != "done":
            continue
        card = task_card_path(root, r["id"])
        if not card:
            continue
        added = _git(["log", "--diff-filter=A", "--format=%ct", "--", str(card.relative_to(root))], root).split()
        if not added:
            continue
        t0 = int(added[-1])
        merges = [int(ts) for ts, subj in log if re.search(rf"\btask/{re.escape(r['id'])}\b", subj) and int(ts) >= t0]
        if merges and min(merges) >= since.timestamp():
            lead.append((min(merges) - t0) / 3600)
    gates_n = 0
    for g in gates(root):
        if g.get("decided_by") == "auto":
            continue
        try:
            c = _dt.datetime.fromisoformat(str(g.get("created") or "")[:10]).replace(tzinfo=_dt.timezone.utc)
        except ValueError:
            c = _dt.datetime.fromtimestamp(os.path.getmtime(g["_path"]), _dt.timezone.utc)
        if c >= since.replace(hour=0, minute=0, second=0, microsecond=0):
            gates_n += 1
    edits = 0
    # no --since: it stops at the first older commit, which is wrong after rebases or clock skew
    out = _git(["log", "-n", "2000", "--format=%x00%ct\t%s", "--", *CONFIG_FILES], root)
    for chunk in out.split("\x00")[1:]:
        ts, _, subj = chunk.strip().partition("\t")
        if not ts.isdigit() or int(ts) < since.timestamp():
            continue
        if not subj.startswith("harness:") and not subj.startswith("chore: add harness"):
            edits += 1
    med = _median(lead)
    return {"lead_time_hours": None if med is None else round(med, 1),
            "interruptions_per_day": round(gates_n / max(days, 1), 1),
            "config_edits": edits, "days": days, "tasks_measured": len(lead)}


def metrics_line(root: Path, days: int = 7) -> str:
    m = metrics(root, days)
    lt = "-" if m["lead_time_hours"] is None else f"{m['lead_time_hours']:.1f}"
    return (f"本周：想法到合并中位 {lt} 小时 · 每天打断 {m['interruptions_per_day']:.1f} 次 · "
            f"手改配置 {m['config_edits']} 次")


# ---------------------------------------------------------------- backlog
def backlog_rows(root: Path) -> list[dict]:
    f = root / ".harness" / "backlog.md"
    if not f.exists():
        return []
    rows = []
    for line in f.read_text(encoding="utf-8").splitlines():
        m = BACKLOG_LINE_RE.match(line.strip())
        if m:
            d = m.groupdict()
            d["deps"] = [x.strip() for x in d["deps"].split(",") if TASK_RE.match(x.strip())]
            rows.append(d)
    return rows


def next_ready(root: Path, skip: set[str] | None = None) -> str | None:
    rows = backlog_rows(root)
    status = {r["id"]: r["status"] for r in rows}
    ready = [r for r in rows if r["status"] == "ready" and r["id"] not in (skip or set())]
    ready.sort(key=lambda r: r["prio"])
    for r in ready:
        if all(status.get(d) in done_like() for d in r["deps"]):
            return r["id"]
    return None


def set_backlog_status(root: Path, task_id: str, status: str, owner: str | None = None) -> bool:
    f = root / ".harness" / "backlog.md"
    if not f.exists():
        return False
    lines, hit = f.read_text(encoding="utf-8").splitlines(), False
    for i, line in enumerate(lines):
        m = BACKLOG_LINE_RE.match(line.strip())
        if m and m.group("id") == task_id:
            d = m.groupdict()
            lines[i] = (f"- {d['id']} | {status} | {d['prio']} | {d['title']} | deps: {d['deps']} | "
                        f"auto_ok: {d['auto']} | owner: {owner if owner is not None else d['owner']}")
            hit = True
    if hit:
        f.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return hit


def sync_merged(root: Path, main_ref: str = "main") -> list[str]:
    """Mark backlog rows in `review` as `done` once their branch is merged
    (ancestor of main, or `gh pr view` says MERGED — covers squash merges)."""
    changed = []
    for r in backlog_rows(root):
        if r["status"] not in ("review", "integrated"):
            continue
        card = task_card_path(root, r["id"])
        br = read_frontmatter(card).get("branch", "") if card else ""
        if not br or "T-000" in br or br.endswith("-slug"):
            cands = [b for b in _git(["branch", "--format=%(refname:short)"], root).splitlines()
                     if re.search(rf"(task/|worktree-){r['id']}\b", b)]
            br = cands[0] if cands else ""
        if not br:
            continue
        merged = subprocess.run(["git", "merge-base", "--is-ancestor", br, main_ref], cwd=root,
                                capture_output=True).returncode == 0 \
            and _git(["rev-parse", br], root) != _git(["rev-parse", main_ref], root)
        if not merged:
            try:
                o = subprocess.run(["gh", "pr", "view", br, "--json", "state", "-q", ".state"], cwd=root,
                                   capture_output=True, text=True, timeout=15)
                merged = o.stdout.strip() == "MERGED"
            except Exception:
                pass
        if merged:
            set_backlog_status(root, r["id"], "done")
            changed.append(r["id"])
            # 教训只从合并后主干上的任务卡取，且只是提议：人批准门卡后由 apply-gate 写进 lessons.md（T-009）
            if card:
                text = _git(["show", f"{main_ref}:{card.relative_to(root).as_posix()}"], root)
                if text:
                    propose_lessons(root, r["id"], text)
    return changed


LESSONS_PROPOSED = ".harness/reports/lessons-proposed.md"


def _lesson_lines(card_text: str) -> list:
    return [l.strip() for l in section(card_text, "12.").splitlines()
            if l.strip().startswith("- ") and len(l.strip()) > 3]


def _proposed_sections(root: Path) -> tuple:
    """-> (头部文字, {小节名: [行]}，小节顺序)"""
    f = root / LESSONS_PROPOSED
    head, secs, order, cur = [], {}, [], None
    for line in (f.read_text(encoding="utf-8").splitlines() if f.exists() else []):
        if line.startswith("## "):
            cur = line[3:].strip()
            if cur not in secs:
                secs[cur] = []
                order.append(cur)
        elif cur is None:
            head.append(line)
        elif line.strip():
            secs[cur].append(line.strip())
    return head, secs, order


def propose_lessons(root: Path, tid: str, card_text: str) -> int:
    """主干任务卡 §12 的候选行 → .harness/reports/lessons-proposed.md 当天小节 + 门卡 G-LESSONS-<日期>（低紧急度）。"""
    import datetime
    gid = "G-LESSONS-" + datetime.date.today().strftime("%Y%m%d")
    lf = root / ".claude" / "rules" / "lessons.md"
    have = lf.read_text(encoding="utf-8") if lf.exists() else ""
    head, secs, order = _proposed_sections(root)
    known = {l for ls in secs.values() for l in ls}
    new = [f"{l}（{tid}）" for l in _lesson_lines(card_text)]
    new = [l for l in dict.fromkeys(new) if l not in known and l not in have.splitlines()]
    if not new:
        return 0
    if gid not in secs:
        secs[gid] = []
        order.append(gid)
    secs[gid] += new
    head = head or ["# 教训提议（sync-merged 写入；批准对应门卡后由人执行 apply-gate 写进 .claude/rules/lessons.md）", ""]
    out = list(head)
    for k in order:
        out += [f"## {k}", *secs[k], ""]
    f = root / LESSONS_PROPOSED
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text("\n".join(out).rstrip("\n") + "\n", encoding="utf-8")
    g = root / ".harness" / "gates" / f"{gid}.md"
    g.parent.mkdir(parents=True, exist_ok=True)
    # 门卡是否还开着看答案库（T-010）：库里已有答案（或读不了）就不再改写卡片
    if not g.exists() or (read_frontmatter(g).get("status") == "open" and gate_state(root, gid) == "open"):
        lines = secs[gid]
        g.write_text(
            f"---\nid: {gid}\ntask: -\nkind: unlock\nstatus: open\nurgency: low\nrecommended: A\ndecided_by: human\n"
            f"review_minutes: 2\ndefault_if_no_answer: 不写进 lessons.md\nblocks: []\nanswer:\napprove_options: [A]\n---\n\n"
            f"# {gid} 把这些教训写进 .claude/rules/lessons.md 吗？\n\n"
            "**为什么需要你：** lessons.md 每个会话都会加载，等于给 Claude 的指令；任务卡里的话机器不能自己放行。\n\n"
            "## 候选\n" + "\n".join(lines) + "\n\n"
            f"## 选项\n- **A（推荐）**：写进去 — 然后由你运行 `{lib_cmd(root)} apply-gate {gid}`\n- **B**：不写\n\n"
            f"**回复格式：** `{gid}: A` 或 `{gid}: B，<备注>`\n", encoding="utf-8")
    return len(new)


def apply_lessons_gate(root: Path, gid: str) -> int:
    """已批准的 G-LESSONS-<日期>：把 lessons-proposed.md 对应小节的行原样追加进 lessons.md（去重）。"""
    _, secs, _ = _proposed_sections(root)
    lf = root / ".claude" / "rules" / "lessons.md"
    old = lf.read_text(encoding="utf-8") if lf.exists() else "# 教训（同一个错误出现两次就记一行，所有会话自动加载）\n\n"
    have = set(old.splitlines())
    add = [l for l in dict.fromkeys(secs.get(gid, [])) if l not in have]
    if add:
        lf.parent.mkdir(parents=True, exist_ok=True)
        lf.write_text(old.rstrip("\n") + "\n" + "\n".join(add) + "\n", encoding="utf-8")
    return len(add)


# ---------------------------------------------------------------- dispatch rules (deterministic)
BUSY = {"claimed", "in_progress", "waiting_human"}


def _literal_prefix(pat: str) -> str:
    pat = _norm(pat)
    m = re.search(r"[*?\[]", pat)
    return pat[:m.start()] if m else pat


def paths_overlap(a: list, b: list) -> bool:
    """Conservative: two scopes overlap when either is unknown (empty) or one pattern's literal
    prefix contains the other's (src/player/** vs src/player/ui/** overlap; src/a/** vs src/b/** do not)."""
    if not a or not b:
        return True
    for x in a:
        for y in b:
            px, py = _literal_prefix(x), _literal_prefix(y)
            if px.startswith(py) or py.startswith(px):
                return True
    return False


def card_fm(root: Path, tid: str) -> dict:
    c = task_card_path(root, tid)
    return read_frontmatter(c) if c else {}


def decide_session(root: Path, tid: str, after: str | None = None, context_pct: int | None = None,
                   unattended: bool = False) -> tuple:
    """Where should `tid` run? -> ("same"|"new", reason). Same conversation only when it is small,
    touches the same files as the task just finished, and the conversation is still light."""
    fm = card_fm(root, tid)
    forced = (fm.get("session") or "auto").lower()
    if forced in ("same", "new"):
        return forced, "任务卡指定"
    if unattended:
        return "new", "无人值守一律新会话"
    if not after:
        return "new", "没有正在进行的对话可接"
    if (fm.get("size") or "M").upper() != "S":
        return "new", f"规模 {fm.get('size') or 'M'}，需要干净上下文"
    if context_pct is not None and context_pct >= 50:
        return "new", f"当前上下文已用 {context_pct}%"
    prev = card_fm(root, after)
    if not paths_overlap(fm.get("allowed_paths") or [], prev.get("allowed_paths") or []) \
            or not (fm.get("allowed_paths") and prev.get("allowed_paths")):
        return "new", "和上一个任务不是同一块代码"
    return "same", "小任务、同一块代码、上下文还轻：/clear 后在本对话继续"


def pick_batch(root: Path, n: int, skip: set | None = None) -> list:
    """Up to n ready tasks (deps done) whose allowed_paths overlap neither each other nor any scoped busy
    task. A task without allowed_paths (unknown scope) is only ever dispatched alone."""
    rows = backlog_rows(root)
    status = {r["id"]: r["status"] for r in rows}
    busy_scopes = [sc for sc in (card_fm(root, r["id"]).get("allowed_paths") or [] for r in rows
                                 if r["status"] in BUSY) if sc]
    chosen, scopes = [], []
    ready = sorted((r for r in rows if r["status"] == "ready" and r["id"] not in (skip or set())),
                   key=lambda r: r["prio"])
    for r in ready:
        if len(chosen) >= n:
            break
        if not all(status.get(d) in done_like() for d in r["deps"]):
            continue
        sc = card_fm(root, r["id"]).get("allowed_paths") or []
        if not sc:
            if not chosen:
                return [r["id"]]
            continue
        if any(paths_overlap(sc, b) for b in busy_scopes + scopes):
            continue
        chosen.append(r["id"])
        scopes.append(sc)
    return chosen


def waves(root: Path) -> list:
    """Dependency layers of the work still to start. Batch 1 = what pick_batch could dispatch now;
    a task waiting on in-flight work (review / in progress / waiting) lands in batch 2 at the earliest."""
    rows = backlog_rows(root)
    done = {r["id"] for r in rows if r["status"] in done_like()}
    todo = {r["id"]: r for r in rows if r["status"] in ("ready", "blocked")}
    inflight = {r["id"] for r in rows if r["id"] not in done and r["id"] not in todo and r["status"] != "proposed"}
    out, placed = [], set(done)
    while todo:
        layer = sorted(t for t, r in todo.items() if all(d in placed for d in r["deps"]))
        if not layer:
            if inflight - placed:
                placed |= inflight
                continue
            out.append(sorted(todo))  # waits on a proposed task or a cycle
            break
        out.append(layer)
        placed |= set(layer) | inflight
        for t in layer:
            todo.pop(t)
    return out


def card_line(root: Path, tid: str, heading: str, n: int = 1) -> str:
    c = task_card_path(root, tid)
    if not c:
        return ""
    body = section(c.read_text(encoding="utf-8"), heading)
    lines = [l.strip(" -") for l in body.splitlines() if l.strip(" -") and not l.strip().startswith(">")]
    return "；".join(lines[:n])


def task_location(root: Path, tid: str) -> Path:
    """The freshest copy of a task card lives in its worktree when there is one."""
    for p, b in worktrees(root):
        if re.search(rf"(task/|worktree-){tid}\b", b or ""):
            return p
    return root


def write_status(root: Path) -> Path:
    """.harness/STATUS.md: one page a teammate reads to know who is doing what, what is stuck and why."""
    rows = backlog_rows(root)
    now = __import__("datetime").datetime.now().strftime("%Y-%m-%d %H:%M")
    out = [f"# 项目状态（自动生成于 {now}，勿手改）", "",
           "| 任务 | 状态 | 负责 | spec | 当前进展 / 卡住的点 | 门卡 |", "|---|---|---|---|---|---|"]
    order = {s: i for i, s in enumerate(["waiting_human", "blocked", "in_progress", "claimed", "review",
                                          "integrated", "ready", "proposed", "done"])}
    for r in sorted(rows, key=lambda r: (order.get(r["status"], 9), r["id"])):
        loc = task_location(root, r["id"])
        fm = card_fm(loc, r["id"])
        prog = card_line(loc, r["id"], "7.", 3) if r["status"] not in ("ready", "proposed", "done") else ""
        og = ",".join(g.get("id", "") for g in open_gates(loc, r["id"]))
        out.append(f"| {r['id']} {r['title'][:24]} | {r['status']} | {r['owner']} | {fm.get('spec', '') or '-'} "
                   f"| {prog[:80] or '-'} | {og or '-'} |")
    mins, items = review_load(root)
    out += ["", f"待人审阅：约 {mins} 分钟（{items} 项）"]
    wv = waves(root)
    if wv:
        out += ["", "## 接下来的批次", ""] + [f"- 第 {i + 1} 批：{', '.join(w)}" for i, w in enumerate(wv)]
    dec = root / ".harness" / "decisions.md"
    if dec.exists():
        d = [l for l in dec.read_text(encoding="utf-8").splitlines() if l.startswith("- D-")][-5:]
        if d:
            out += ["", "## 最近决策", ""] + d
    p = root / ".harness" / "STATUS.md"
    p.write_text("\n".join(out) + "\n", encoding="utf-8")
    return p


def sync_lessons(root: Path, tid: str, wt: Path) -> int:
    """Copy new lines from a task card's 「12. 教训」 into .claude/rules/lessons.md (auto-loaded by every session)."""
    c = task_card_path(wt, tid)
    if not c:
        return 0
    return append_lessons(root, tid, c.read_text(encoding="utf-8"))


def append_lessons(root: Path, tid: str, card_text: str) -> int:
    new = [l.strip() for l in section(card_text, "12.").splitlines()
           if l.strip().startswith("- ") and len(l.strip()) > 3]
    lf = root / ".claude" / "rules" / "lessons.md"
    old = lf.read_text(encoding="utf-8") if lf.exists() else "# 教训（同一个错误出现两次就记一行，所有会话自动加载）\n\n"
    added = [f"{l}（{tid}）" for l in new if l[2:].strip() not in old]
    if added:
        lf.write_text(old.rstrip("\n") + "\n" + "\n".join(added) + "\n", encoding="utf-8")
    return len(added)


def morning(root: Path, integ_log: Path | None, integ_branch: str = "") -> str:
    """At most ~20 lines: what landed (with evidence), what is stuck and why, what to read first."""
    rows = backlog_rows(root)
    cnt = {}
    for r in rows:
        cnt[r["status"]] = cnt.get(r["status"], 0) + 1
    out = ["# 晨报", "", "状态：" + "，".join(f"{k} {v}" for k, v in sorted(cnt.items()))]
    events = []
    if integ_log and integ_log.exists():
        for l in integ_log.read_text(encoding="utf-8").splitlines():
            try:
                events.append(__import__("json").loads(l))
            except ValueError:
                pass
    ok = [e for e in events if e.get("result") == "green"]
    bad = [e for e in events if e.get("result") != "green"]
    if ok:
        out.append(f"已整合进 {integ_branch or '整合分支'}：" + "；".join(
            f"{e['task']}（{e.get('commit', '')[:7]}，`{e.get('verify', '')}` exit 0）" for e in ok[:6]))
    if bad:
        landed = {e["task"] for e in ok}
        out.append("整合失败已撤回、任务重开：" + "；".join(
            f"{e['task']}（{e.get('result')}{'，重试后已整合' if e['task'] in landed else '，仍未整合'}）" for e in bad[:4]))
    stuck = [r for r in rows if r["status"] in ("blocked", "waiting_human")]
    for r in stuck[:5]:
        loc = task_location(root, r["id"])
        why = card_line(loc, r["id"], "7.", 4)
        og = ",".join(g.get("id", "") for g in open_gates(loc, r["id"]))
        out.append(f"卡住 {r['id']} {r['status']}：{(og + ' ') if og else ''}{why[:90] or '见任务卡第 7 节'}")
    # 3 diffs to read first: high risk first, then the biggest change
    cand = []
    for e in ok:
        loc = task_location(root, e["task"])
        fm = card_fm(loc, e["task"])
        cand.append(({"high": 0, "medium": 1}.get(fm.get("risk", "low"), 2), -int(e.get("lines", 0)), e))
    if cand:
        out.append("先看这 3 个 diff：")
        for _, _, e in sorted(cand, key=lambda x: (x[0], x[1]))[:3]:
            c7 = e.get("commit", "")[:7]
            out.append(f"  - {e['task']}：`git diff {c7}^1 {c7}`（{e.get('lines', 0)} 行，risk "
                       f"{card_fm(task_location(root, e['task']), e['task']).get('risk', 'low')}）")
    mins, items = review_load(root)
    if items:
        out.append(f"待你审阅：约 {mins} 分钟（{items} 项）")
    autos = [gid for gid, a in store_answers(store_main(root)) if a.get("via") == "auto"]  # the store, not cards
    if autos:
        out.append(f"Claude 按信任阶梯代你决定了 {len(autos)} 项（可抽查）：" + "，".join(autos[:5]))
    sug = [d for d in trust_stats(root) if d["suggest"]]
    if sug:
        out.append("可以少问你：" + "；".join(f"{d['kind']} 类 {d['agree']}/{d['n']} 次和推荐一致" for d in sug[:2])
                   + "（`harness_lib.py trust` 查看）")
    lf = root / ".claude" / "rules" / "lessons.md"
    if lf.exists():
        les = [l for l in lf.read_text(encoding="utf-8").splitlines() if l.startswith("- ")][-2:]
        if les:
            out.append("新教训：" + " / ".join(les))
    try:
        out.append(metrics_line(root))
    except Exception:  # metrics must never break the morning report
        pass
    return "\n".join(out[:22]) + "\n"


def board(root: Path) -> str:
    """Global state for the control tower, read fresh from files every time."""
    out = []
    rows = backlog_rows(root)
    by = {}
    for r in rows:
        by.setdefault(r["status"], []).append(r)
    order = ["in_progress", "claimed", "waiting_human", "review", "ready", "proposed", "blocked", "done"]
    for st in order:
        if by.get(st):
            items = ", ".join(f"{r['id']}({r['prio']} {r['title'][:18]})" for r in by[st][:8])
            out.append(f"{st:<13} {len(by[st]):>2}  {items}")
    done_ids = {r["id"] for r in rows if r["status"] == "done"}
    wts_all = [(p, b) for p, b in worktrees(root) if TASK_RE.search(b or "")]
    stale = [TASK_RE.search(b).group(1) for p, b in wts_all if TASK_RE.search(b).group(1) in done_ids]
    wts = [(p, b) for p, b in wts_all if TASK_RE.search(b).group(1) not in done_ids]
    if wts:
        out.append("worktrees:")
        for p, b in wts:
            tid = TASK_RE.search(b).group(1)
            c = task_card_path(p, tid)
            fm = read_frontmatter(c) if c else {}
            un = len(unchecked_items(c.read_text(encoding="utf-8"))) if c else 0
            og = [g.get("id") for g in open_gates(p, tid)]
            out.append(f"  {tid:<6} {fm.get('status', '?'):<13} 未完成 {un:>2}  门卡 {','.join(og) or '-'}  {p}")
    gates_all, unknown = {}, []
    main = store_main(root)
    retire_vanished(main)
    for p, _b in reversed(worktrees(root) or [(root, "")]):
        for g in gates(Path(p)):
            snapshot_meta(main, gate_id(g))  # first sight by the control plane freezes the gate's meaning
            if gate_state(main, gate_id(g)) == "unknown" and gate_id(g) not in unknown:
                unknown.append(gate_id(g))
        for g in open_gates(p):
            gates_all.setdefault(gate_id(g), g)
    if unknown:
        out.append("状态未知（答案库读不了，既不算开着也不算已答）: " + ", ".join(unknown))
    if gates_all:
        out.append("等你答复的门卡:")
        for g in sorted(gates_all.values(), key=lambda g: (g.get("urgency") != "high", g.get("id", ""))):
            gid = gate_id(g)
            meta = read_meta(main, gid) or {}
            out.append(f"  {gid:<12} {meta.get('kind', '?'):<12} {g.get('urgency', 'normal'):<6} "
                       f"Issue {read_issue(main, gid) or '-'}"
                       + (f"  放开：{', '.join(meta['paths'])}" if meta.get("kind") == "unlock" and meta.get("paths") else ""))
    if stale:
        out.append("已合并、可清理的 worktree: " + ", ".join(stale) + "（git worktree remove .claude/worktrees/<任务号>）")
    wv = waves(root)
    if wv:
        out.append("批次: " + "  →  ".join("[" + " ".join(w) + "]" for w in wv))
    nxt = pick_batch(root, 3)
    out.append("可并行派发: " + (", ".join(nxt) if nxt else "无（考虑 /backlog-groom）"))
    return "\n".join(out)


# ---------------------------------------------------------------- context for skills
def current(cwd: str) -> tuple[Path | None, str, str | None, Path | None]:
    root = repo_root(cwd)
    if not root:
        return None, "", None, None
    br = current_branch(cwd)
    tid = task_id_for(root, br)
    card = task_card_path(root, tid) if tid else None
    return root, br, tid, card


def cmd_where(cwd: str) -> str:
    root, br, tid, card = current(cwd)
    if not root:
        return "不是 git 仓库"
    mc = main_checkout(cwd)
    lines = [
        f"仓库根: {root}",
        f"主仓库: {mc}",
        f"linked worktree: {'yes' if is_linked_worktree(cwd) else 'no'}",
        f"分支: {br or '(detached)'}",
        f"当前任务: {tid or '无'}" + (f"  卡: {card.relative_to(root)}" if card else ""),
    ]
    if card:
        fm = read_frontmatter(card)
        lines.append(f"任务状态: {fm.get('status')}  session: {fm.get('session')}  risk: {fm.get('risk')}")
    return "\n".join(lines)


def cmd_context(cwd: str, which: str) -> str:
    root, br, tid, card = current(cwd)
    if not root:
        return "(不是 git 仓库)"
    out = [cmd_where(cwd), ""]
    locks = read_locks(root)
    out.append("全局冻结路径: " + (", ".join(p for p, _ in locks) or "无"))
    broot = main_checkout(cwd) if is_linked_worktree(cwd) else root  # backlog lives in main checkout
    broot = broot if broot and (broot / ".harness").exists() else root
    og = open_gates(root)
    out.append("待处理门卡: " + (", ".join(f"{g.get('id')}({g.get('task')},{g.get('kind')})" for g in og) or "无"))
    rows = backlog_rows(broot)
    if rows:
        out.append("backlog（主仓库）:" if broot != root else "backlog:")
        out += [f"  {r['id']} {r['status']:<13} {r['prio']} {r['title']} deps={','.join(r['deps']) or '-'} auto_ok={r['auto']}"
                for r in rows if r["status"] != "done"]
        nr = next_ready(broot)
        out.append(f"下一个可认领: {nr or '无（考虑 /backlog-groom）'}")
    if which in ("run", "close") and card:
        txt = card.read_text(encoding="utf-8")
        un = unchecked_items(txt)
        out.append(f"未完成项({len(un)}): " + ("; ".join(u[6:60] for u in un[:8]) or "无"))
        if which == "close":
            ho = root / ".harness" / "handoffs" / f"{tid}.md"
            out.append(f"交接包: {'已存在' if ho.exists() else '未写'}")
            out.append("未提交改动文件数: " + str(len([l for l in _git(['status', '--short'], cwd).splitlines() if l])))
    if which == "align":
        ids = [int(m.group(1)[2:]) for p in glob.glob(str(root / ".harness" / "tasks" / "T-*.md"))
               if (m := TASK_RE.search(os.path.basename(p)))]
        ids += [int(r["id"][2:]) for r in rows]
        out.append(f"下一个任务编号: T-{(max(ids) + 1 if ids else 1):03d}")
        dec = root / ".harness" / "decisions.md"
        if dec.exists():
            d = [l for l in dec.read_text(encoding='utf-8').splitlines() if l.startswith("- D-")]
            out.append("最近决策:\n  " + "\n  ".join(d[-8:]) if d else "最近决策: 无")
    if which == "tower":
        return cmd_where(cwd) + "\n\n" + board(broot)
    if which == "groom":
        out.append("最近提交:\n  " + _git(["log", "--oneline", "-n", "15"], cwd).replace("\n", "\n  "))
    return "\n".join(out)


# ---------------------------------------------------------------- strict launcher (S-002 T-008)
CONTROL_PATHS = [
    ".claude/settings.json", ".claude/settings.local.json", ".claude/hooks/**", ".claude/skills/**",
    ".claude/agents/**", ".claude/commands/**", ".claude/rules/**", ".mcp.json", "CLAUDE.md", "scripts/**",
    ".github/**", ".gitattributes", ".gitignore", ".worktreeinclude",
    ".harness/verify.sh", ".harness/quick-check.sh", ".harness/allow-commands.txt", ".harness/locks.txt",
    ".harness/auto-decide.txt", ".harness/decisions.md", ".harness/backlog.md", ".harness/lib/**", ".harness/logs/**",
    "CLAUDE.local.md", ".gitmodules", ".lfsconfig", ".claude/output-styles/**",
]
# 只给 control-diff 用的扩展清单：通配项沙箱写不了（且任务 worktree 本身就在 .claude/worktrees/ 下）
CONTROL_GLOBS = CONTROL_PATHS + [".claude/**", "**/CLAUDE.md", "**/.gitattributes"]
PLAN_WRITABLE = {".harness/backlog.md", ".harness/tasks", ".harness/gates"}
CREDENTIAL_DIRS = {"~/.ssh", "~/.gnupg", "~/.aws", "~/.config/gcloud", "~/.azure", "~/.kube"}
CREDENTIAL_FILES = ["~/.config/git/credentials", "~/.git-credentials", "~/.docker/config.json", "~/.netrc",
                    "~/.npmrc", "~/.yarnrc.yml", "~/.pypirc", "~/.cargo/credentials", "~/.cargo/credentials.toml"]
SCRUB_ENV = {"GH_TOKEN", "GITHUB_TOKEN", "HARNESS_GH_TOKEN", "HARNESS_SERVE_TOKEN", "HARNESS_TELEGRAM_TOKEN",
             "SSH_AUTH_SOCK", "SSH_ASKPASS", "GIT_ASKPASS", "DOCKER_HOST", "GOOGLE_APPLICATION_CREDENTIALS"}
SCRUB_SUFFIXES = ("_TOKEN", "_SECRET", "_KEY", "_PASSWORD", "_PAT", "_APIKEY", "_AUTHTOKEN", "_PASS", "_PWD",
                  "_CREDENTIALS")
URL_PASSWORD = re.compile(r"://[^/@\s:]+:[^/@\s]+@")
KEEP_ENV = {"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"}
DENIED_DOMAINS = ["api.telegram.org", "webhook.site", "pastebin.com", "paste.ee", "hastebin.com",
                  "transfer.sh", "0x0.st", "requestbin.com", "pipedream.net"]
STACK_DOMAINS = [
    (("package.json",), ["registry.npmjs.org", "registry.yarnpkg.com"]),
    (("pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "requirements-dev.txt"),
     ["pypi.org", "files.pythonhosted.org"]),
    (("go.mod",), ["proxy.golang.org", "sum.golang.org"]),
    (("Cargo.toml",), ["crates.io", "index.crates.io", "static.crates.io"]),
]
SRT_FIX = "缺少 Anthropic sandbox-runtime（拦截 Unix socket 的过滤器）：npm install -g @anthropic-ai/sandbox-runtime"
SANDBOX_FIX = {
    "linux": "沙箱需要 bubblewrap 和 socat：sudo apt-get install bubblewrap socat（Fedora：sudo dnf install bubblewrap socat）",
    "wsl2": "沙箱需要 bubblewrap 和 socat：sudo apt-get install bubblewrap socat",
    "wsl1": "Claude Code 沙箱需要 WSL2：在 PowerShell 里运行 wsl --set-version <发行版> 2，或改用 WSL2 发行版",
    "windows": "原生 Windows 没有 Claude Code 沙箱：请在 WSL2 里运行 harness（wsl --install）",
}


class LaunchError(Exception):
    def __init__(self, code: int, msg: str):
        super().__init__(msg)
        self.code = code


def state_dir(main: Path) -> Path:
    import hashlib
    base = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")
    key = hashlib.sha1(str(main.resolve()).encode()).hexdigest()[:8]
    return base / "harness" / f"{main.name}-{key}"


def config_dir() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "harness"


def detect_platform() -> str:
    forced = os.environ.get("HARNESS_PLATFORM", "").strip().lower()
    if forced:
        return forced
    if sys.platform == "darwin":
        return "macos"
    if os.name == "nt" or sys.platform.startswith(("win", "cygwin", "msys")):
        return "windows"
    try:
        rel = Path("/proc/sys/kernel/osrelease").read_text().lower()
    except OSError:
        rel = ""
    if "microsoft" in rel:
        return "wsl2" if "wsl2" in rel or "microsoft-standard" in rel else "wsl1"
    return "linux"


def sandbox_problem(platform: str) -> str:
    """'' when the Claude Code sandbox can run here, else a one-line fix."""
    import shutil
    if platform in ("wsl1", "windows"):
        return SANDBOX_FIX[platform]
    if platform in ("linux", "wsl2"):
        missing = [b for b in ("bwrap", "socat") if not shutil.which(b)]
        if missing:
            return f"缺少 {', '.join(missing)}。" + SANDBOX_FIX[platform]
        if not srt_runner():
            return SRT_FIX
    return ""


def stack_domains(root: Path) -> list:
    out, manifests = [], []
    for files, doms in STACK_DOMAINS:
        hit = [root / f for f in files if (root / f).exists()]
        if hit:
            out += doms
            manifests += hit
    text = "\n".join(p.read_text(encoding="utf-8", errors="replace") for p in manifests)
    if re.search(r"github\.com|git\+|github:", text):
        out += ["github.com", "codeload.github.com"]
    return list(dict.fromkeys(out))


def _abs(p) -> str:
    return "/" + str(p)  # Claude Code settings: //absolute/path


def credential_paths() -> tuple:
    """-> (dirs, files) with ~ or absolute (//) forms, resolving where gh actually keeps its config."""
    xdg = os.environ.get("XDG_CONFIG_HOME")
    dirs = list(CREDENTIAL_DIRS) + ["~/.config/gh"]
    if xdg:
        dirs.append(_abs(Path(xdg).expanduser().resolve() / "gh"))
    if os.environ.get("GH_CONFIG_DIR"):
        dirs.append(_abs(Path(os.environ["GH_CONFIG_DIR"]).expanduser().resolve()))
    return sorted(dict.fromkeys(dirs)), list(CREDENTIAL_FILES)


def _exists(p: str) -> bool:
    return Path(p[1:] if p.startswith("//") else p).expanduser().exists()


def strict_settings(root: Path, role: str = "task", tid: str = "") -> dict:
    """The --settings file for a strict launch. Task cards and gates are NOT consulted: Claude can write them.
    Only an unlock approval in the answers store (task == tid, letter A) lifts the control paths it snapshotted,
    and only inside this worktree (T-010)."""
    root = root.resolve()
    main = main_checkout(root)
    if main is None:
        raise LaunchError(3, f"{root} 不是 git 仓库（或找不到 git）：strict 模式无法确定要保护的路径")
    main = main.resolve()
    git = main / ".git"
    rule_write, allow_write, git_deny = [], [], []
    if role == "plan":
        # 规划运行在主仓库：除任务卡、门卡、backlog 外，主仓库现有条目一律只读
        for entry in sorted(main.iterdir()):
            if entry.name != ".harness":
                rule_write.append(_abs(entry) + ("/**" if entry.is_dir() else ""))
        for entry in sorted((main / ".harness").iterdir()) if (main / ".harness").is_dir() else []:
            if f".harness/{entry.name}" not in PLAN_WRITABLE:
                rule_write.append(_abs(entry) + ("/**" if entry.is_dir() else ""))
        rule_write += [_abs(main / c) for c in CONTROL_PATHS if c not in PLAN_WRITABLE]
    else:
        bases = list(dict.fromkeys([root, main]))
        lifted = set(unlocked_paths(main, tid)) if (role == "task" and tid and root != main) else set()
        rule_write += [_abs(b / c) for b in bases for c in CONTROL_PATHS if not (b == root and c in lifted)]
        rule_write += [_abs(git / x) + "/**" for x in ("hooks", "info")]
        git_deny += [_abs(git / x) for x in ("config", "refs/heads/main", "refs/heads/master", "packed-refs")]
        if root != main:
            # 链接的 worktree：Claude Code 已为它放开主仓库 .git（hooks/config 除外），这里把不属于它的部分逐一拒绝
            own_gd = _git(["rev-parse", "--path-format=absolute", "--git-dir"], root)
            branch = current_branch(root)
            own_ref = "refs/heads/" + branch
            top = branch.rsplit("/", 1)[0] if "/" in branch else ""
            allow_write = [_abs(git / "objects")]
            if top:  # 同目录下其他分支的 ref 文件在下面逐一拒绝
                allow_write += [_abs(git / "refs" / "heads" / top), _abs(git / "logs" / "refs" / "heads" / top)]
            if own_gd:
                allow_write.append(_abs(Path(own_gd)))
            git_deny += [_abs(git / "HEAD"), _abs(git / "index")]
            for wt in sorted((git / "worktrees").glob("*")) if (git / "worktrees").is_dir() else []:
                if own_gd and wt.resolve() != Path(own_gd).resolve():
                    git_deny.append(_abs(wt))
            for ref in sorted((git / "refs" / "heads").rglob("*")):
                if ref.is_file() and ref.relative_to(git).as_posix() != own_ref:
                    git_deny.append(_abs(ref))
    rule_write = list(dict.fromkeys(rule_write + git_deny))
    # 沙箱路径写目录本身。控制路径即使还不存在也要拒绝（否则 Bash 能新建它们）；沙箱会在那里放占位文件，
    # 控制面把这些名字写进 .git/info/exclude，免得被 git add 收进去。.git 里只拒绝现有路径（占位文件会弄坏 ref）。
    deny_write = list(dict.fromkeys(x[:-3] if x.endswith("/**") else x for x in rule_write))
    deny_write = [p for p in deny_write if _exists(p) or not p.startswith(_abs(git) + "/")]
    sd, cd = state_dir(main), config_dir()
    cdirs, cfiles = credential_paths()
    hdirs = [_abs(sd.parent), _abs(cd)]
    deny_read = cdirs + cfiles + hdirs
    perm = ([f"Read({p}/**)" for p in cdirs + hdirs] + [f"Read({p})" for p in cfiles]
            + [f"{verb}({p})" for p in rule_write for verb in ("Edit", "Write")]
            + ["WebFetch", "WebSearch"])
    return {
        "sandbox": {
            "enabled": True, "failIfUnavailable": True, "allowUnsandboxedCommands": False,
            "autoAllowBashIfSandboxed": True,
            "filesystem": {"allowWrite": allow_write, "denyRead": deny_read, "denyWrite": deny_write},
            "network": {"allowedDomains": stack_domains(root), "deniedDomains": list(DENIED_DOMAINS)},
        },
        "permissions": {"deny": perm},
    }


def scrub_env(env: dict) -> dict:
    keep = KEEP_ENV | {k.strip() for k in env.get("HARNESS_KEEP_ENV", "").split(",") if k.strip()}
    out = {k: v for k, v in env.items()
           if k in keep or k.upper().endswith("_PROXY")  # 带账号的代理是 Claude 连 API 所需
           or not (k.upper() in SCRUB_ENV or k.upper().endswith(SCRUB_SUFFIXES) or URL_PASSWORD.search(v or ""))}
    out["HARNESS_STRICT"] = "1"
    return out


def exclude_placeholders(main: Path, data: dict) -> None:
    """沙箱给不存在的 denyWrite 路径放 0 字节占位文件：把这些仓库内路径写进 .git/info/exclude（控制面做，Claude 写不了它）。"""
    names = set()
    for p in data["sandbox"]["filesystem"]["denyWrite"]:
        q = Path(p[1:] if p.startswith("//") else p)
        if q.exists():
            continue
        for base in [main] + [w for w, _ in worktrees(main)]:
            try:
                names.add("/" + q.relative_to(Path(base).resolve()).as_posix())
                break
            except ValueError:
                continue
    if not names:
        return
    ex = main / ".git" / "info" / "exclude"
    ex.parent.mkdir(parents=True, exist_ok=True)
    have = set(ex.read_text(encoding="utf-8").splitlines()) if ex.exists() else set()
    # 只忽略占位文件；真目录（如分支里新建的 .github/）不忽略，git 看得见，control-diff 才拦得住（T-009）
    add = sorted(n for n in names if n not in have) + sorted(f"!{n}/" for n in names if f"!{n}/" not in have)
    if add:
        with ex.open("a", encoding="utf-8") as f:
            f.write("".join(f"{n}\n" for n in ["# harness strict: sandbox placeholders"] * (not have.intersection(names)) + add))


def write_strict_settings(root: Path, role: str = "task", tid: str = "") -> Path:
    import tempfile
    data = strict_settings(root, role, tid)
    main = main_checkout(root.resolve()).resolve()
    exclude_placeholders(main, data)
    d = state_dir(main)
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    name = "strict-settings.json" if role == "task" and not tid else f"strict-settings-{role}-{tid or 'x'}.json"
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(d))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, d / name)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return d / name


STRICT_FRESH_DAYS = 7


def _launch_dir(main: Path) -> Path:
    """Per-checkout launch records, beside (not in) state_dir(main); denied to the sandbox like the state dir."""
    sd = state_dir(main)
    return sd.parent / f"{sd.name}.launches"


def record_launch(root: Path, strict: bool) -> None:
    """Launcher: remember when a strict / standard Claude last started in this checkout (root)."""
    import hashlib
    import time
    try:
        root = Path(root).resolve()
        main = main_checkout(root)
        if not main:
            return
        d = _launch_dir(main.resolve())
        d.mkdir(parents=True, exist_ok=True)
        os.chmod(d, 0o700)
        f = d / (hashlib.sha1(str(root).encode()).hexdigest()[:16] + ".json")
        data = _read_json(f) or {}
        data["root"] = str(root)
        data["strict" if strict else "standard"] = time.time()
        _replace_json(f, data)
    except OSError:
        pass


def _harness_now() -> float:
    import time
    try:
        return float(os.environ.get("HARNESS_NOW") or time.time())
    except ValueError:
        return time.time()


def strict_checkouts(main: Path) -> set:
    """Resolved roots of the checkouts whose last launch was strict and at most 7 days ago (now = HARNESS_NOW if
    set). Strict evidence: the launcher's record for that checkout, and its settings files
    (strict-settings-task-<TID>.json -> that task's worktree, strict-settings-plan-*.json -> the main checkout,
    strict-settings.json -> the checkout its record names). A later standard launch there cancels it; one checkout's
    launches never count for another. Their hooks publish nothing (T-011), so gate-sync publishes their gates."""
    main = store_main(main)
    recs = {}
    try:
        for f in _launch_dir(main).glob("*.json"):
            try:
                d = _read_json(f) or {}
                if d.get("root"):
                    recs[str(Path(d["root"]).resolve())] = d
            except OSError:
                pass
    except OSError:
        pass
    strict_at = {r: float(d.get("strict") or 0) for r, d in recs.items()}
    wts = worktrees(main)
    try:
        for f in state_dir(main).glob("strict-settings*.json"):
            mt = f.stat().st_mtime
            m = re.fullmatch(r"strict-settings-task-(T-\d{3,})\.json", f.name)
            roots = []
            if m:
                roots = [str(Path(p).resolve()) for p, br in wts
                         if re.fullmatch(rf"task/{m.group(1)}-.*|worktree-{m.group(1)}", br or "")]
            elif f.name.startswith("strict-settings-plan-"):
                roots = [str(main)]
            for r in roots:
                strict_at[r] = max(strict_at.get(r, 0.0), mt)
    except OSError:
        pass
    now = _harness_now()
    return {r for r, t in strict_at.items()
            if t > 0 and t > float((recs.get(r) or {}).get("standard") or 0) and now - t <= STRICT_FRESH_DAYS * 86400}


def launch_argv(args: list, root: Path, strict: bool, role: str = "task", tid: str = "",
                env: dict | None = None) -> tuple:
    """-> (argv, env, problem). problem != '' means: refuse to start."""
    env = dict(os.environ if env is None else env)
    claude = env.get("HARNESS_CLAUDE", "claude")
    if not strict:
        record_launch(root, False)
        return [claude, *args], env, ""
    problem = sandbox_problem(detect_platform())
    if problem:
        return [], env, problem
    try:
        path = write_strict_settings(root, role, tid)
    except LaunchError as e:
        return [], env, str(e)
    record_launch(root, True)
    return [claude, "--settings", str(path), *args], scrub_env(env), ""


def cmd_launch(argv: list) -> int:
    if "--" not in argv and "--print-settings" not in argv:
        print("用法：harness_lib.py launch [--strict] [--role task|plan] [--task T-xxx] [--root DIR] -- <claude 参数>",
              file=sys.stderr)
        return 2
    rest = argv[argv.index("--") + 1:] if "--" in argv else []
    opts = argv[:argv.index("--")] if "--" in argv else argv
    vals = {}
    i = 0
    while i < len(opts):
        o = opts[i]
        if o in ("--root", "--role", "--task"):
            if i + 1 >= len(opts) or opts[i + 1].startswith("--"):
                print(f"✗ {o} 缺少值", file=sys.stderr)
                return 2
            vals[o] = opts[i + 1]
            i += 2
        else:
            i += 1
    root = Path(vals.get("--root", os.getcwd())).resolve()
    role, tid = vals.get("--role", "task"), vals.get("--task", "")
    if role not in ("task", "plan"):
        print(f"✗ --role 只能是 task 或 plan，收到 {role}", file=sys.stderr)
        return 2
    strict = "--strict" in opts or os.environ.get("HARNESS_UNATTENDED") == "1"
    if "--print-settings" in opts:
        try:
            print(json.dumps(strict_settings(root, role, tid), ensure_ascii=False, indent=2))
        except LaunchError as e:
            print(f"✗ {e}", file=sys.stderr)
            return e.code
        return 0
    cmd, env, problem = launch_argv(rest, root, strict, role, tid)
    if problem:
        print(f"✗ strict 模式无法启动 Claude：{problem}", file=sys.stderr)
        return 3
    os.chdir(root)
    try:
        os.execvpe(cmd[0], cmd, env)
    except OSError as e:
        print(f"✗ 无法启动 {cmd[0]}: {e}", file=sys.stderr)
        return 127
    return 0


# ---------------------------------------------------------------- control-path guard & sandboxed verify (S-002 T-009)
def control_diff(root, base: str, branch: str) -> list[str]:
    """Control paths changed on <branch> since its merge base with <base> (renames count both names, deletes count).
    Only CONTROL_PATHS: task cards / gates on the branch are NOT consulted (Claude can write them)."""
    import unicodedata
    for ref in (base, branch):
        if not ref or ref.startswith("-"):
            raise LaunchError(2, f"无效的 ref：{ref!r}")
    try:
        r = subprocess.run([*GIT_SAFE, "diff", "--name-only", "--no-renames", "-z",
                            "--no-ext-diff", "--no-textconv", f"{base}...{branch}", "--"],
                           cwd=str(root), capture_output=True, timeout=120)
    except (OSError, subprocess.SubprocessError) as e:
        raise LaunchError(2, f"git diff {base}...{branch} 失败：{e}")
    if r.returncode != 0:
        raise LaunchError(2, f"git diff {base}...{branch} 失败：{r.stderr.decode('utf-8', 'replace').strip()}")
    names = r.stdout.decode("utf-8", "surrogateescape").split("\0")  # 非 UTF-8 文件名按原字节保留
    # 大小写 / Unicode 归一后再比：大小写不敏感的文件系统上 SCRIPTS/x.sh 就是 scripts/x.sh（宁可多拦）
    fold = lambda s: unicodedata.normalize("NFC", s).casefold()
    pats = [fold(c) for c in CONTROL_GLOBS]
    # 控制路径的上级目录本身出现在 diff 里，说明那里换成了符号链接 / 子模块 / 文件（如 .claude/commands -> src/x）：同样算命中
    anc = set()
    for c in pats:
        lit = []
        for part in c.split("/")[:-1]:
            if any(ch in part for ch in "*?["):
                break
            lit.append(part)
            anc.add("/".join(lit))
    return sorted({p for p in names if p and (fold(p) in anc or matches_any(fold(p), pats))})


GIT_SAFE = ["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.quotePath=false"]


def task_branch(root: Path, tid: str) -> str:
    """任务分支名：主仓库任务卡的 branch:，缺省规则同 new-task.sh。"""
    br = card_branch(root, tid)
    return br if re.match(rf"^task/{re.escape(tid)}-\S+$", br) else ""


def card_branch(root: Path, tid: str) -> str:
    """主仓库任务卡写的分支名（未经校验）；缺省规则同 new-task.sh。"""
    card = task_card_path(root, tid)
    if not card:
        return ""
    br = str(read_frontmatter(card).get("branch", "") or "")
    if not br or "T-000" in br or br.endswith("-slug"):
        slug = re.sub(rf"^{re.escape(tid)}-?", "", card.stem) or "task"
        br = f"task/{tid}-{slug}"
    return br


def default_branch(root) -> str:
    """origin/HEAD → init.defaultBranch → main → master 中第一个有本地分支的；都没有抛 LaunchError(2)。"""
    root = str(root)

    def git(*a):
        try:
            r = subprocess.run([*GIT_SAFE, *a], cwd=root, capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            return ""
        return r.stdout.strip() if r.returncode == 0 else ""

    def local(b):
        return bool(b) and not b.startswith("-") and \
            subprocess.run([*GIT_SAFE, "show-ref", "--verify", "--quiet", f"refs/heads/{b}"], cwd=root,
                           capture_output=True).returncode == 0
    oh = git("symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
    cands = [oh[len("origin/"):] if oh.startswith("origin/") else "", git("config", "init.defaultBranch"), "main", "master"]
    for b in cands:
        if local(b):
            return b
    raise LaunchError(2, "找不到默认分支（origin/HEAD、init.defaultBranch、main、master 都没有本地分支）")


def srt_runner() -> str | None:
    import shutil
    return shutil.which(os.environ.get("HARNESS_SRT") or "srt")


def _write_private(path: Path, data: dict) -> Path:
    import tempfile
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return path


def srt_settings(root: Path, workdir: Path | None = None) -> dict:
    """strict_settings 的沙箱部分转成 srt 自己的格式：//abs → /abs，去掉结尾 /**。
    可写：给了 workdir 时只有 workdir 和 TMPDIR，否则 root 和 TMPDIR。网络白名单取自主仓库（main 检出）的清单文件。"""
    sb = strict_settings(root, "task")["sandbox"]
    main = main_checkout(root.resolve()).resolve()
    one = lambda p: (p[1:] if p.startswith("//") else p)[:-3] if p.endswith("/**") else (p[1:] if p.startswith("//") else p)
    conv = lambda ps: list(dict.fromkeys(one(p) for p in ps))
    fs = sb["filesystem"]
    tmp = str(Path(os.environ.get("TMPDIR") or "/tmp").resolve())
    return {
        "network": {"allowedDomains": stack_domains(main),
                    "deniedDomains": list(sb["network"]["deniedDomains"])},
        "filesystem": {"denyRead": conv(fs["denyRead"] + ["~/.claude", "~/.claude.json"]),
                       "allowWrite": conv([str(Path(workdir).resolve()), tmp] if workdir is not None
                                          else fs["allowWrite"] + [str(root.resolve()), tmp]),
                       "denyWrite": conv(fs["denyWrite"])},
    }


def verify_env(env: dict) -> dict:
    """验证进程的环境：同 scrub_env，但没有保留名单（Anthropic 凭证、HARNESS_KEEP_ENV、带账号的代理一律删）。"""
    out = {k: v for k, v in env.items()
           if k != "HARNESS_KEEP_ENV" and k not in KEEP_ENV
           and not (k.upper() in SCRUB_ENV or k.upper().endswith(SCRUB_SUFFIXES) or URL_PASSWORD.search(v or ""))}
    out["HARNESS_STRICT"] = "1"
    return out


def sandboxed_cmd(cmd: list, root, workdir=None) -> tuple:
    """-> (argv, env)：在 srt 沙箱里、无凭证地运行 cmd。找不到 srt 抛 LaunchError(3, SRT_FIX)。
    给了 workdir（一次性导出目录）时 srt 只能写 workdir 和 TMPDIR。"""
    runner = srt_runner()
    if not runner:
        raise LaunchError(3, SRT_FIX)
    root = Path(root).resolve()
    sb = strict_settings(root, "task")["sandbox"]
    main = main_checkout(root).resolve()
    exclude_placeholders(main, {"sandbox": sb})
    path = _write_private(state_dir(main) / "srt-settings-verify.json", srt_settings(root, workdir))
    env = verify_env(dict(os.environ))
    if workdir is not None:  # 导出目录往上找不到任何 git 仓库（比如放在 git 管理的 home 里）
        env["GIT_CEILING_DIRECTORIES"] = str(Path(workdir).resolve().parent)
    return [runner, "--settings", str(path), *cmd], env


def _rmtree(p: Path) -> None:
    import shutil
    import stat

    def fix(func, path, _exc):
        try:
            os.chmod(os.path.dirname(path), 0o700)
            os.chmod(path, stat.S_IRWXU)
            func(path)
        except OSError:
            pass
    shutil.rmtree(p, onerror=fix)


def export_root(main: Path) -> Path:
    """导出目录的父目录：<XDG_STATE_HOME>/harness-exports/<仓库>-<hash>（在被拒读的 harness 状态树之外）。"""
    sd = state_dir(main)
    return sd.parent.parent / "harness-exports" / sd.name


def export_commit(root: Path, commit: str) -> Path:
    """git archive <commit> 流式解到 export_root(主仓库)/verify-*（700，没有 git 目录）。commit 无效抛 LaunchError(2)。
    取舍：没有被 git 忽略的文件、没有子模块内容、export-ignore 生效。"""
    import tarfile
    import tempfile
    if not commit or commit.startswith("-"):
        raise LaunchError(2, f"无效的提交：{commit!r}")
    r = subprocess.run([*GIT_SAFE, "rev-parse", "--verify", "--quiet", f"{commit}^{{commit}}"],
                       cwd=str(root), capture_output=True, text=True, timeout=30)
    sha = r.stdout.strip()
    if r.returncode != 0 or not sha:
        raise LaunchError(2, f"找不到提交 {commit}")
    er = export_root(main_checkout(root).resolve())
    er.mkdir(parents=True, exist_ok=True)
    os.chmod(er.parent, 0o700)
    os.chmod(er, 0o700)
    d = Path(tempfile.mkdtemp(prefix="verify-", dir=str(er))).resolve()
    base_filter = getattr(tarfile, "data_filter", None)

    def safe(m, path):  # 指向导出目录外的链接、绝对路径等直接跳过
        if base_filter:
            try:
                return base_filter(m, path)
            except tarfile.FilterError:
                return None
        if m.name.startswith("/") or ".." in m.name.split("/") or m.islnk() or \
                (m.issym() and (m.linkname.startswith("/") or ".." in m.linkname.split("/"))):
            return None
        return m
    try:
        with tempfile.TemporaryFile() as err:
            p = subprocess.Popen([*GIT_SAFE, "archive", "--format=tar", sha], cwd=str(root),
                                 stdout=subprocess.PIPE, stderr=err)
            try:
                with tarfile.open(fileobj=p.stdout, mode="r|") as tf:  # 流式：不把整个 tar 读进内存
                    for m in tf:
                        m2 = safe(m, str(d))
                        if m2 is None:
                            continue
                        if base_filter:
                            tf.extract(m2, str(d), filter="fully_trusted")
                        else:
                            tf.extract(m2, str(d))
            finally:
                p.stdout.close()
                rc = p.wait()
            if rc != 0:
                err.seek(0)
                raise LaunchError(2, f"git archive {sha} 失败：{err.read().decode('utf-8', 'replace').strip()}")
    except (tarfile.TarError, OSError) as e:
        _rmtree(d)
        raise LaunchError(2, f"导出 {sha} 失败：{e}")
    except BaseException:
        _rmtree(d)
        raise
    return d


def cmd_sandbox_run(argv: list) -> int:
    if "--check" in argv:
        if srt_runner():
            print("ok")
            return 0
        print(SRT_FIX)
        return 3
    if "--" not in argv or not argv[argv.index("--") + 1:]:
        print("用法：harness_lib.py sandbox-run [--root DIR] -- <命令…> | sandbox-run --check", file=sys.stderr)
        return 2
    opts, rest = argv[:argv.index("--")], argv[argv.index("--") + 1:]
    for o in ("--root", "--export"):
        if o in opts and opts.index(o) + 1 >= len(opts):
            print(f"✗ {o} 缺少值", file=sys.stderr)
            return 2
    root = Path(opts[opts.index("--root") + 1] if "--root" in opts else os.getcwd()).resolve()
    if "--export" in opts:  # 一次性导出目录里跑，跑完（无论成败）删除
        if not srt_runner():
            print(f"✗ {SRT_FIX}", file=sys.stderr)
            return 3
        try:
            wd = export_commit(root, opts[opts.index("--export") + 1])
        except LaunchError as e:
            print(f"✗ {e}", file=sys.stderr)
            return e.code
        try:
            cmd, env = sandboxed_cmd(rest, root, wd)
            rc = subprocess.run(cmd, cwd=str(wd), env=env).returncode
            return rc if rc >= 0 else 128 - rc
        except LaunchError as e:
            print(f"✗ {e}", file=sys.stderr)
            return e.code
        except OSError as e:
            print(f"✗ 无法启动 {rest[0]}: {e}", file=sys.stderr)
            return 127
        finally:
            _rmtree(wd)
    try:
        cmd, env = sandboxed_cmd(rest, root)
    except LaunchError as e:
        print(f"✗ {e}", file=sys.stderr)
        return e.code
    os.chdir(root)
    try:
        os.execve(cmd[0], cmd, env)
    except OSError as e:
        print(f"✗ 无法启动 {cmd[0]}: {e}", file=sys.stderr)
        return 127
    return 0


def cmd_control_diff(argv: list) -> int:
    pos, root, i = [], os.getcwd(), 0
    while i < len(argv):
        if argv[i] == "--root":
            if i + 1 >= len(argv):
                print("✗ --root 缺少值", file=sys.stderr)
                return 2
            root, i = argv[i + 1], i + 2
        else:
            pos.append(argv[i])
            i += 1
    if len(pos) not in (1, 2):
        print("用法：harness_lib.py control-diff [<base>] <branch> [--root DIR]（省略 base = 默认分支）", file=sys.stderr)
        return 2
    try:
        if len(pos) == 1:
            pos = [default_branch(root), pos[0]]
        hits = control_diff(Path(root), pos[0], pos[1])
    except LaunchError as e:
        print(f"✗ {e}", file=sys.stderr)
        return 2
    sys.stdout.flush()
    for h in hits:
        sys.stdout.buffer.write(h.encode("utf-8", "surrogateescape") + b"\n")
    sys.stdout.flush()
    return 1 if hits else 0


def main(argv: list[str]) -> int:
    cwd = os.getcwd()
    if not argv:
        print(__doc__)
        return 0
    cmd = argv[0]
    if cmd == "launch":
        return cmd_launch(argv[1:])
    if cmd == "control-diff":
        return cmd_control_diff(argv[1:])
    if cmd == "sandbox-run":
        return cmd_sandbox_run(argv[1:])
    if cmd == "task-branch":
        root = main_checkout(cwd) or repo_root(cwd)
        if not root or len(argv) < 2:
            print("用法：harness_lib.py task-branch T-xxx", file=sys.stderr)
            return 2
        br = task_branch(root, argv[1])
        if not br:
            print(f"任务卡的分支 {card_branch(root, argv[1]) or '?'} 不是 task/{argv[1]}-…", file=sys.stderr)
            return 1
        print(br)
        return 0
    if cmd == "default-branch":
        root = argv[argv.index("--root") + 1] if "--root" in argv[1:-1] else cwd
        try:
            print(default_branch(root))
        except LaunchError as e:
            print(f"✗ {e}", file=sys.stderr)
            return 2
        return 0
    if cmd == "sandbox-check":
        problem = sandbox_problem(detect_platform())
        print(problem or "ok")
        return 3 if problem else 0
    if cmd == "where":
        print(cmd_where(cwd))
    elif cmd == "current-path":
        _, _, _, card = current(cwd)
        print(card or "")
    elif cmd == "context":
        print(cmd_context(cwd, argv[1] if len(argv) > 1 else "run"))
    elif cmd == "next-ready":
        root = repo_root(cwd)
        skip = set(argv[argv.index("--skip") + 1].split(",")) if "--skip" in argv else set()
        print((next_ready(root, skip) if root else "") or "")
    elif cmd == "set-status":
        root = repo_root(cwd)
        tid, st = argv[1], argv[2]
        owner = argv[argv.index("--owner") + 1] if "--owner" in argv else None
        ok = set_backlog_status(root, tid, st, owner)
        card = None if "--backlog-only" in argv else task_card_path(root, tid)
        if card:
            set_frontmatter_field(card, "status", st)
        print(f"backlog={'ok' if ok else 'miss'} card={'ok' if card else 'miss'}")
    elif cmd == "sync-merged":
        root = repo_root(cwd)
        print(" ".join(sync_merged(root)) if root else "")
    elif cmd == "merge-pr":  # control plane only (harness-loop finish): merge gate -> PR it opened
        root = main_checkout(cwd) or repo_root(cwd)
        if len(argv) != 2:  # T-011 v2: no CLI writes PR mappings (only the scheduler, in-process)
            print("✗ merge-pr 只读：PR 映射只由调度器在控制面记录", file=sys.stderr)
            return 2
        n = read_pr(root, merge_gid(argv[1])) if root and TASK_RE.fullmatch(argv[1]) else None
        print(n or "")
        return 0 if n else 1
    elif cmd == "goal":
        note = argv[argv.index("--note") + 1] if "--note" in argv else ""
        print(goal_prompt(argv[1], note, strict="--strict" in argv))
    elif cmd == "decide":
        root = repo_root(cwd)
        after = argv[argv.index("--after") + 1] if "--after" in argv else None
        ctx = int(argv[argv.index("--context") + 1]) if "--context" in argv else None
        mode, why = decide_session(root, argv[1], after, ctx, os.environ.get("HARNESS_UNATTENDED") == "1")
        print(f"{mode}\t{why}")
    elif cmd == "pick-batch":
        root = repo_root(cwd)
        skip = set(argv[argv.index("--skip") + 1].split(",")) if "--skip" in argv else set()
        print(" ".join(pick_batch(root, int(argv[1]), skip)))
    elif cmd == "backlog-status":
        root = main_checkout(cwd) or repo_root(cwd)
        print(next((r["status"] for r in backlog_rows(root) if r["id"] == argv[1]), ""))
    elif cmd == "status":
        print(write_status(main_checkout(cwd) or repo_root(cwd)))
    elif cmd == "waves":
        for i, w in enumerate(waves(main_checkout(cwd) or repo_root(cwd))):
            print(f"第 {i + 1} 批: {' '.join(w)}")
    elif cmd == "lessons":
        root = main_checkout(cwd) or repo_root(cwd)
        print(sync_lessons(root, argv[1], Path(argv[2])))
    elif cmd == "morning":
        root = main_checkout(cwd) or repo_root(cwd)
        log = Path(argv[argv.index("--log") + 1]) if "--log" in argv else None
        br = argv[argv.index("--branch") + 1] if "--branch" in argv else ""
        print(morning(root, log, br), end="")
    elif cmd == "board":
        print(board(main_checkout(cwd) or repo_root(cwd)))
    elif cmd == "critics":
        # critics <risk> [verify|spec]  -> one angle per line (no output = no adversarial review needed)
        for a in critic_plan(argv[1] if len(argv) > 1 else "low", argv[2] if len(argv) > 2 else "verify"):
            print(a)
    elif cmd == "metrics":
        days = int(argv[argv.index("--days") + 1]) if "--days" in argv else 7
        m = metrics(main_checkout(cwd) or repo_root(cwd), days)
        for k in ("lead_time_hours", "interruptions_per_day", "config_edits", "tasks_measured", "days"):
            print(f"{k}\t{'-' if m[k] is None else m[k]}")
    elif cmd == "review-load":
        m, n = review_load(main_checkout(cwd) or repo_root(cwd))
        print(f"{m}\t{n}")
    elif cmd == "trust":
        root = main_checkout(cwd) or repo_root(cwd)
        if "--apply" in argv:
            kind = argv[argv.index("--apply") + 1]
            ok = apply_policy(root, kind)
            print(f"{'已允许' if ok else '不允许'} Claude 代你决定 {kind} 类门卡" +
                  ("" if ok else "（irreversible/external/unlock 永远问你）"))
            return 0 if ok else 1
        rows = trust_stats(root)
        if not rows:
            print("还没有足够的决定记录（门卡要有 recommended 和你的 answer）。")
        for d in rows:
            tag = "已放权" if d["auto"] else ("建议放权" if d["suggest"] else ("永远问你" if d["kind"] in NEVER_AUTO else "继续问"))
            print(f"{d['kind']:<12} {d['agree']}/{d['n']} 一致（{d['rate']:.0%}）  {tag}")
        for d in rows:
            if d["suggest"]:
                print(f"→ 放权：{lib_cmd(root)} trust --apply {d['kind']}   （只能你自己执行）")
    elif cmd == "gate-policy":
        print(gate_policy(main_checkout(cwd) or repo_root(cwd), argv[1]))
    elif cmd == "apply-gate":
        # Human-only: apply an approved gate's then_policy / then_rules (in-session answers can't touch locked files).
        root = main_checkout(cwd) or repo_root(cwd)
        gid = argv[1] if len(argv) > 1 else ""
        a = read_answer(root, gid) if root else None
        meta = read_meta(root, gid) if root else None
        if not find_gate_card(root, gid) or not a or a.get("_bad") or a.get("letter") != "A" or not meta:
            print("门卡不存在或答案库里没有批准")
            return 1
        if gid.startswith("G-LESSONS-"):  # T-009: approved lessons proposal -> lessons.md
            print("lessons added:", apply_lessons_gate(root, gid))
        if meta.get("then_policy"):  # what the gate meant when first seen, not the card now
            print("policy:", apply_policy(root, meta["then_policy"]))
        if meta.get("then_rules"):
            print("rules added:", apply_rules(root, meta["then_rules"], gid))
    elif cmd == "answer":
        # Human-only (guard_bash denies Claude): answer a gate from your own terminal.
        if len(argv) < 3:
            print("用法：harness_lib.py answer <门卡号> <选项字母> [备注]", file=sys.stderr)
            return 2
        main_dir = main_checkout(cwd) or repo_root(cwd)
        yes = "--yes" in argv[3:]
        gid, letter, note = argv[1], argv[2].strip().upper(), " ".join(a for a in argv[3:] if a != "--yes")
        meta = snapshot_meta(main_dir, gid) if main_dir else None
        if not meta:
            print(f"✗ 找不到门卡 {gid}（只认任务自己的 worktree 或主仓库里的门卡）", file=sys.stderr)
            return 2
        if letter not in meta_letters(meta):
            print(f"✗ {gid} 没有选项 {letter}（可选：{'/'.join(meta_letters(meta))}）", file=sys.stderr)
            return 2
        if gate_state(main_dir, gid) == "unknown":
            print(f"✗ 答案库读不了，{gid} 的状态未知；先检查 {answers_dir(main_dir)} 的权限", file=sys.stderr)
            return 1
        print(f"{gid} {meta.get('title', '')}\nkind: {meta.get('kind', '')}")
        for o in meta.get("options") or []:
            print(f"{o['letter']}：{o.get('text', '')}")
        if meta.get("kind") == "unlock":
            print(f"paths: {', '.join(meta.get('paths') or []) or '-'}")
        prev = read_answer(main_dir, gid)
        if prev is None:
            card = find_gate_card(main_dir, gid)
            diff = meaning_diff(meta, card) if card else []
            if card and card_changed(meta, card):
                print("注意：卡片在快照后改过；按快照（上面）记录。")
            if diff and not yes:
                print("✗ 门卡的类别 / 问题 / 选项和控制面第一次见到时不同，没有记录：\n  " + "\n  ".join(diff)
                      + f"\n确认按快照（上面）答复：加 --yes 再运行一次。", file=sys.stderr)
                return 3
        if prev is not None:
            print(f"✗ {gid} 已答复过：{prev.get('letter')}（via {prev.get('via')}），只认第一次", file=sys.stderr)
            return 1
        ok, status, tid = answer_gate(main_dir, gid, letter, note, "终端")
        if not ok:
            print(f"✗ {gid} 已答复过，只认第一次", file=sys.stderr)
            return 1
        print(f"✓ {gid}：{letter} → {status}" + (f"；{tid} 解除阻塞，下一次 gate-sync 接续" if tid else ""))
    elif cmd == "migrate-answers":
        # Human-only: import v0.1 answers written on gate cards into the store (once, at upgrade).
        main_dir = main_checkout(cwd) or repo_root(cwd)
        if not main_dir:
            print("✗ 不是 git 仓库", file=sys.stderr)
            return 1
        n_ans, gids = migrate_answers(main_dir)
        print(f"已导入 {n_ans} 个答案（已有的不覆盖；门卡、decisions.md 与 Issue 映射未改）" + (f"：{', '.join(gids)}" if gids else ""))
    elif cmd == "show":
        main_dir = main_checkout(cwd) or repo_root(cwd)
        txt = gate_show(main_dir, argv[1]) if main_dir and len(argv) > 1 else None
        if not txt:
            print(f"✗ 找不到门卡 {argv[1] if len(argv) > 1 else ''}", file=sys.stderr)
            return 2
        print(txt)
    elif cmd == "card-status":
        root = Path(argv[argv.index("--root") + 1]) if "--root" in argv else repo_root(cwd)
        card = task_card_path(root, argv[1]) if root else None
        print(read_frontmatter(card).get("status", "") if card else "")
    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
