#!/usr/bin/env bash
# T-021 验收：任务不自锁、解锁后接续（S-003 #6 #8；现场报告 F-9、F-12；T-018 §8 finding 7）。按任务卡 T-021「接口约定」。
# 起点是 project 文档 S-003-adjustments 的复现脚本 S-2：答复后只有 waiting_human 能接续，blocked 的任务没有出口。
# 全部在临时仓库里跑；XDG_STATE_HOME 指向临时目录（答案库）；不碰 GitHub（不调用 gate-sync）。
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-t021.XXXXXX")"; T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
unset HARNESS_GUARD HARNESS_MODE HARNESS_UNATTENDED HARNESS_GATE_CHANNEL HARNESS_SERVE_TOKEN
export XDG_STATE_HOME="$T/state" HARNESS_GATE_PUSH_ASSETS=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
python3 -B - "$SRC/.claude/hooks" "$SRC" "$T" <<'PY'
import contextlib, io, json, os, re, subprocess, sys, time, traceback
from pathlib import Path

HOOKS, PKG, TMP = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
sys.path.insert(0, str(HOOKS))
import harness_lib as H  # noqa: E402

N = FAILS = 0


def expect(name, want, fn):
    global N, FAILS
    N += 1
    try:
        got = fn() if callable(fn) else fn
    except Exception as e:  # a missing function / crash is a failure, not a test error
        got = f"ERR {type(e).__name__}: {e}"
    if got == want:
        print(f"PASS {name}")
    else:
        FAILS += 1
        print(f"FAIL {name} (want {want!r}, got {got!r})")


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


def mkrepo(name, backlog_rows=()):
    repo = TMP / name
    for d in ("tasks", "gates", "handoffs"):
        (repo / ".harness" / d).mkdir(parents=True, exist_ok=True)
    git(TMP, "init", "-q", "-b", "main", str(repo))
    (repo / ".gitignore").write_text(".claude/worktrees/\n__pycache__/\n", encoding="utf-8")
    write_backlog(repo, backlog_rows)
    return repo.resolve()


def write_backlog(repo, rows):
    lines = ["# Backlog", ""] + [f"- {t} | {st} | P1 | demo {t} | deps: - | auto_ok: no | owner: -" for t, st in rows]
    (repo / ".harness" / "backlog.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def card(root, tid, status, allowed=None, locked=None, unlock=None):
    allowed = allowed if allowed is not None else f"src/{tid}/**"
    p = root / ".harness" / "tasks" / f"{tid}-x.md"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(f"---\nid: {tid}\ntitle: demo {tid}\nstatus: {status}\nbranch: task/{tid}-x\n"
                 f"allowed_paths: [{allowed}]\nlocked_paths: [{locked or ''}]\nunlock: [{unlock or ''}]\n"
                 f"gates: []\n---\n\n# {tid} demo\n", encoding="utf-8")
    return p


def gate(root, gid, kind, paths=None, body_extra=""):
    p = root / ".harness" / "gates" / f"{gid}.md"
    p.parent.mkdir(parents=True, exist_ok=True)
    pl = f"paths: {paths}\n" if paths is not None else ""
    p.write_text(f"---\nid: {gid}\nkind: {kind}\nstatus: open\nrecommended: A\n{pl}answer:\n---\n\n"
                 f"# {gid} 能不能解锁？\n\n- **A（推荐）**：解锁\n- **B**：不解锁\n{body_extra}", encoding="utf-8")
    return p


def status(root, tid):
    c = H.task_card_path(root, tid)
    return H.read_frontmatter(c).get("status", "") if c else "<no card>"


def blog(main, tid):
    return next((r["status"] for r in H.backlog_rows(main) if r["id"] == tid), "<no row>")


def cli(cwd, *args):
    r = subprocess.run([sys.executable, "-B", str(HOOKS / "harness_lib.py"), *args], cwd=str(cwd),
                       capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def has_meta(main, gid):
    return (H.answers_dir(main) / f"{gid}.meta.json").exists()


# ================================================================ S-2：答复后接续（主仓库，复现脚本改写）
A = mkrepo("s2", [("T-001", "waiting_human"), ("T-002", "blocked"), ("T-003", "blocked"), ("T-004", "blocked"),
                  ("T-005", "blocked"), ("T-006", "blocked"), ("T-007", "blocked"), ("T-008", "in_progress"),
                  ("T-010", "blocked"), ("T-011", "in_progress")])
card(A, "T-001", "waiting_human"); gate(A, "G-T001-1", "unlock", "[src/T-001/**]")
card(A, "T-002", "blocked");       gate(A, "G-T002-1", "unlock", "[src/x/**]")
card(A, "T-003", "blocked");       gate(A, "G-T003-1", "ambiguity")
card(A, "T-004", "blocked");       gate(A, "G-T004-1", "unlock", "[src/T-004/**]")
card(A, "T-005", "blocked");       gate(A, "G-T005-1", "ambiguity"); gate(A, "G-T005-2", "ambiguity")
card(A, "T-006", "blocked");       gate(A, "G-T006-1", "unlock")                      # 没有 paths，任务卡也没有 unlock:
card(A, "T-007", "blocked");       gate(A, "G-T007-1", "unlock", "[/etc/**, ../x]")   # 只有不合格的路径
card(A, "T-008", "in_progress");   gate(A, "G-T008-1", "unlock", "src/y/")             # 标量写法
card(A, "T-011", "in_progress", unlock="scripts/**"); gate(A, "G-T011-1", "unlock")   # v0.2 兼容：退回任务卡 unlock:
card(A, "T-010", "blocked");       gate(A, "G-T010-1", "unlock", "[src/T-010/**]")
gate(A, "G-T009-ctl", "unlock"); gate(A, "G-GROOM-1", "unlock")                       # 控制面门卡、非任务门卡：不要求 paths
git(A, "add", "-A"); git(A, "commit", "-qm", "init")

# --- unlock 批准（带 paths）：blocked → 卡与 backlog 都 ready，调度器派发
r = H.answer_gate(A, "G-T002-1", "A", "", "终端")
expect("S-2 unlock+paths: answer recorded, approved", (True, "approved"), lambda: r[:2])
expect("S-2 unlock+paths: settle reports the unblocked task", "T-002", lambda: r[2])
expect("S-2 unlock+paths: task card blocked -> ready", "ready", lambda: status(A, "T-002"))
expect("S-2 unlock+paths: backlog row blocked -> ready", "ready", lambda: blog(A, "T-002"))
expect("S-2 unlock+paths: no .resume marker (dispatched by pick-batch, not resumed)", False,
       lambda: (H.answers_dir(A) / "G-T002-1.resume").exists())
expect("S-2 unlock+paths: snapshot paths come from the gate card", ["src/x/**"],
       lambda: (H.read_meta(A, "G-T002-1") or {}).get("paths"))
expect("S-2 unlock+paths: pick_batch dispatches T-002", True, lambda: "T-002" in H.pick_batch(A, 20))

# --- ambiguity 已答复（任何字母）：blocked → ready，调度器派发
r = H.answer_gate(A, "G-T003-1", "B", "按乙方案", "终端")
expect("S-2 ambiguity: answer B recorded as answered", (True, "answered"), lambda: r[:2])
expect("S-2 ambiguity: settle reports the unblocked task", "T-003", lambda: r[2])
expect("S-2 ambiguity: task card blocked -> ready", "ready", lambda: status(A, "T-003"))
expect("S-2 ambiguity: backlog row blocked -> ready", "ready", lambda: blog(A, "T-003"))
expect("S-2 ambiguity: pick_batch dispatches T-003", True, lambda: "T-003" in H.pick_batch(A, 20))

# --- unlock 被拒：保持 blocked
r = H.answer_gate(A, "G-T004-1", "B", "", "终端")
expect("S-2 unlock rejected: recorded as rejected", (True, "rejected", None), lambda: r)
expect("S-2 unlock rejected: card stays blocked", "blocked", lambda: status(A, "T-004"))
expect("S-2 unlock rejected: backlog stays blocked", "blocked", lambda: blog(A, "T-004"))
expect("S-2 unlock rejected: not dispatched", False, lambda: "T-004" in H.pick_batch(A, 20))

# --- 还有没答复的门卡：保持 blocked；全答完才 ready
H.answer_gate(A, "G-T005-1", "A", "", "终端")
expect("S-2 one of two gates answered: card stays blocked", "blocked", lambda: status(A, "T-005"))
expect("S-2 one of two gates answered: backlog stays blocked", "blocked", lambda: blog(A, "T-005"))
H.answer_gate(A, "G-T005-2", "A", "", "终端")
expect("S-2 both gates answered: card ready", "ready", lambda: status(A, "T-005"))
expect("S-2 both gates answered: backlog ready", "ready", lambda: blog(A, "T-005"))

# --- waiting_human 照旧（回归）：in_progress + RESUME
r = H.answer_gate(A, "G-T001-1", "A", "", "终端")
expect("S-2 waiting_human (regression): settle reports T-001", (True, "approved", "T-001"), lambda: r)
expect("S-2 waiting_human (regression): card -> in_progress", "in_progress", lambda: status(A, "T-001"))
expect("S-2 waiting_human (regression): resume marker queued", True,
       lambda: (H.answers_dir(A) / "G-T001-1.resume").exists())

# --- 终端 answer：成功行写明转 ready；pick-batch CLI 派发
rc, out, err = cli(A, "answer", "G-T010-1", "A")
expect("S-2 CLI answer: exit 0", 0, rc)
expect("S-2 CLI answer: success line names the task and ready", True, "T-010" in out and "ready" in out)
expect("S-2 CLI answer: card ready", "ready", lambda: status(A, "T-010"))
expect("S-2 CLI answer: backlog ready", "ready", lambda: blog(A, "T-010"))
rc, out, err = cli(A, "pick-batch", "20")
expect("S-2 CLI pick-batch: lists T-010", True, "T-010" in out.split())

# ================================================================ unlock 门卡必须带 paths
err_buf = io.StringIO()
with contextlib.redirect_stderr(err_buf):
    m6 = H.snapshot_meta(A, "G-T006-1")
expect("no paths: snapshot_meta returns None", None, m6)
expect("no paths: no meta file written", False, lambda: has_meta(A, "G-T006-1"))
expect("no paths: unlock_paths_missing names the gate and paths:", True,
       lambda: "G-T006-1" in H.unlock_paths_missing(A, "G-T006-1") and "paths:" in H.unlock_paths_missing(A, "G-T006-1"))
expect("no paths: notice shows how to write it (paths: [)", True,
       lambda: "paths: [" in H.unlock_paths_missing(A, "G-T006-1"))
expect("no paths: answer_gate refuses", False, lambda: H.answer_gate(A, "G-T006-1", "A", "", "终端")[0])
expect("no paths: nothing in the store", None, lambda: H.read_answer(A, "G-T006-1"))
expect("no paths: task stays blocked", "blocked", lambda: status(A, "T-006"))
rc, out, err = cli(A, "answer", "G-T006-1", "A")
expect("no paths: CLI answer exit 2", 2, rc)
expect("no paths: CLI answer stderr names the gate and paths:", True, "G-T006-1" in err and "paths:" in err)
expect("no paths: CLI answer recorded nothing", None, lambda: H.read_answer(A, "G-T006-1"))
rc, out, err = cli(A, "show", "G-T006-1")
expect("no paths: CLI show exit 2 with the paths: notice", (2, True), (rc, "paths:" in err and "G-T006-1" in err))
expect("no paths: still no meta after CLI", False, lambda: has_meta(A, "G-T006-1"))
expect("valid gate: unlock_paths_missing is empty", "", lambda: H.unlock_paths_missing(A, "G-T002-1"))
expect("invalid-only paths (/etc/**, ../x): treated as missing", (None, True),
       lambda: (H.snapshot_meta(A, "G-T007-1"), bool(H.unlock_paths_missing(A, "G-T007-1"))))
expect("scalar paths: src/y/ -> [src/y/**]", ["src/y/**"], lambda: (H.snapshot_meta(A, "G-T008-1") or {}).get("paths"))
expect("compat: no gate paths -> task card unlock: still snapshotted", ["scripts/**"],
       lambda: (H.snapshot_meta(A, "G-T011-1") or {}).get("paths"))
expect("exempt: scheduler's G-Txxx-ctl unlock gate still snapshotted", True, lambda: H.snapshot_meta(A, "G-T009-ctl") is not None)
expect("exempt: non-task unlock gate (G-GROOM-…) still snapshotted", True, lambda: H.snapshot_meta(A, "G-GROOM-1") is not None)
# 补上 paths 后正常快照、答复、接续
gate(A, "G-T006-1", "unlock", "[src/T-006/**]")
expect("paths added later: snapshot taken", ["src/T-006/**"], lambda: (H.snapshot_meta(A, "G-T006-1") or {}).get("paths"))
expect("paths added later: answer records and unblocks", (True, "approved", "T-006"),
       lambda: H.answer_gate(A, "G-T006-1", "A", "", "终端"))
expect("paths added later: card + backlog ready", ("ready", "ready"), lambda: (status(A, "T-006"), blog(A, "T-006")))

# ================================================================ F-12 真实场景：任务与门卡在 worktree 里
B = mkrepo("wt", [("T-020", "blocked")])
card(B, "T-020", "claimed")
git(B, "add", "-A"); git(B, "commit", "-qm", "init")
WB = (TMP / "wt-T020")
git(B, "worktree", "add", "-q", "-b", "task/T-020-x", str(WB))
WB = WB.resolve()
card(WB, "T-020", "blocked"); gate(WB, "G-T020-1", "unlock", "[src/T-020/**]")
r = H.answer_gate(B, "G-T020-1", "A", "", "终端")
expect("worktree: gate in the task's worktree answered", (True, "approved", "T-020"), lambda: r)
expect("worktree: worktree task card -> ready", "ready", lambda: status(WB, "T-020"))
expect("worktree: main task card -> ready (new-task.sh can claim)", "ready", lambda: status(B, "T-020"))
expect("worktree: main backlog row -> ready", "ready", lambda: blog(B, "T-020"))
expect("worktree: pick_batch on main dispatches T-020", ["T-020"], lambda: H.pick_batch(B, 5))

# ================================================================ 任务自己的文件 / locked_paths / unlock 放开
C = mkrepo("own", [("T-201", "in_progress"), ("T-202", "ready")])
for f, txt in (("src/core/a.py", "a\n"), ("src/other/o.py", "o\n"), ("LICENSE", "L\n"), (".harness/notes.md", "n\n")):
    (C / f).parent.mkdir(parents=True, exist_ok=True); (C / f).write_text(txt, encoding="utf-8")
card(C, "T-201", "in_progress", allowed="src/**", locked=".harness/**, src/core/**, LICENSE")
card(C, "T-202", "ready")
git(C, "add", "-A"); git(C, "commit", "-qm", "init")
WC = TMP / "own-T201"
git(C, "worktree", "add", "-q", "-b", "task/T-201-x", str(WC))
WC = WC.resolve()

own = [".harness/tasks/T-201-x.md", ".harness/tasks/T-201.md", ".harness/handoffs/T-201.md", ".harness/gates/G-T201-1.md",
       ".harness/gates/G-T201-2/shot.png"]
notown = [".harness/tasks/T-2010-x.md", ".harness/gates/G-T2010-1.md", ".harness/gates/G-T202-1.md",
          ".harness/tasks/T-202-x.md", ".harness/backlog.md", ".harness/decisions.md"]
expect("own_task_paths: own files match", [], lambda: [p for p in own if not H.matches_any(p, H.own_task_paths("T-201"))])
expect("own_task_paths: other tasks' / shared files do not", [],
       lambda: [p for p in notown if H.matches_any(p, H.own_task_paths("T-201"))])
expect("own_task_paths: bad task id -> []", [], lambda: H.own_task_paths("foo"))


def pp(rel, cwd=WC, tool="Write"):
    data = {"tool_name": tool, "cwd": str(cwd), "tool_input": {"file_path": str(cwd / rel), "content": "x\n"}}
    r = subprocess.run([sys.executable, "-B", str(HOOKS / "protect_paths.py")], input=json.dumps(data),
                       capture_output=True, text=True, cwd=str(cwd))
    return "deny" if '"deny"' in r.stdout else "allow"


expect("protect_paths: own task card writable despite locked_paths .harness/**", "allow", lambda: pp(".harness/tasks/T-201-x.md"))
expect("protect_paths: own handoff writable", "allow", lambda: pp(".harness/handoffs/T-201.md"))
expect("protect_paths: own new gate card writable", "allow", lambda: pp(".harness/gates/G-T201-2.md"))
expect("protect_paths: own gate asset writable", "allow", lambda: pp(".harness/gates/G-T201-2/shot.png"))
expect("protect_paths: another task's gate still locked", "deny", lambda: pp(".harness/gates/G-T202-1.md"))
expect("protect_paths: T-2010 card is not T-201's", "deny", lambda: pp(".harness/tasks/T-2010-x.md"))
expect("protect_paths: decisions.md still locked by .harness/**", "deny", lambda: pp(".harness/decisions.md"))
expect("protect_paths: locked src/core before approval", "deny", lambda: pp("src/core/a.py"))


def strict():
    return H.strict_settings(WC, "task", "T-201")


def dw_blocks(s, path):
    a = "/" + str(path)
    return any(a == e or a.startswith(e.rstrip("/") + "/") for e in s["sandbox"]["filesystem"]["denyWrite"])


def rule_blocks(s, path):
    a = "/" + str(path)
    for r in s["permissions"]["deny"]:
        m = re.fullmatch(r"(Edit|Write)\((.*)\)", r)
        if m and H.glob_to_regex(m.group(2)).match(a):
            return True
    return False


ownabs = [WC / ".harness/tasks/T-201-x.md", WC / ".harness/handoffs/T-201.md", WC / ".harness/gates/G-T201-1.md",
          WC / ".harness/gates/G-T201-9.md", WC / ".harness/gates/G-T201-9/shot.png"]
S0 = None
try:
    S0 = strict()
except Exception as e:
    print(f"  (strict_settings raised {type(e).__name__}: {e})")
expect("strict: own paths not under any denyWrite entry", [], lambda: [str(p) for p in ownabs if dw_blocks(S0, p)])
expect("strict: own paths not matched by any Edit/Write deny", [], lambda: [str(p) for p in ownabs if rule_blocks(S0, p)])
expect("strict: .harness/notes.md (locked by .harness/**) still denied: denyWrite + Edit/Write", (True, True),
       lambda: (dw_blocks(S0, WC / ".harness/notes.md"), rule_blocks(S0, WC / ".harness/notes.md")))
expect("strict: another task's card still denied", True, lambda: dw_blocks(S0, WC / ".harness/tasks/T-202-x.md"))
expect("strict: src/core locked before approval", (True, True),
       lambda: (dw_blocks(S0, WC / "src/core/a.py"), rule_blocks(S0, WC / "src/core/a.py")))
expect("strict: LICENSE locked", True, lambda: dw_blocks(S0, WC / "LICENSE") and rule_blocks(S0, WC / "LICENSE"))


def commit_wc(msg, files):
    for f, txt in files.items():
        (WC / f).parent.mkdir(parents=True, exist_ok=True)
        (WC / f).write_text(txt, encoding="utf-8")
    git(WC, "add", "-A"); git(WC, "commit", "-qm", msg)
    return git(WC, "rev-parse", "HEAD")


def cdiff(sha, task="T-201"):
    return H.control_diff(C, "main", sha, task=task)


c1 = (WC / ".harness/tasks/T-201-x.md").read_text(encoding="utf-8").replace("status: in_progress", "status: in_progress\nsession: auto")
sha1 = commit_wc("own bookkeeping", {".harness/tasks/T-201-x.md": c1, ".harness/handoffs/T-201.md": "# handoff\n",
                                     ".harness/gates/G-T201-1.md": gate(WC, "G-T201-1", "unlock", "[src/core/**]").read_text(encoding="utf-8")})
expect("control-diff: own card / handoff / gate are not locked_paths hits", [], lambda: cdiff(sha1))
sha2 = commit_wc("shared", {".harness/notes.md": "n2\n", ".harness/tasks/T-202-x.md": "---\nid: T-202\nstatus: done\n---\n"})
expect("control-diff: other .harness files still hit .harness/**", [".harness/notes.md", ".harness/tasks/T-202-x.md"],
       lambda: cdiff(sha2))
sha3 = commit_wc("core", {"src/core/a.py": "a2\n"})
expect("control-diff: locked src/core/a.py hits before approval", True, lambda: "src/core/a.py" in cdiff(sha3))
sha4 = commit_wc("license", {"LICENSE": "L2\n"})

# 批准 G-T201-1（paths: [src/core/**]）：只放开 src/core/**
expect("unlock: card status: approved alone does nothing", True,
       lambda: (H.set_frontmatter_field(WC / ".harness/gates/G-T201-1.md", "status", "approved") or True)
       and "src/core/a.py" in cdiff(sha3))
H.set_frontmatter_field(WC / ".harness/gates/G-T201-1.md", "status", "open")
expect("unlock: store approval of G-T201-1", True, lambda: H.answer_gate(C, "G-T201-1", "A", "", "终端")[0])
S1 = None
try:
    S1 = strict()
except Exception as e:
    print(f"  (strict_settings raised {type(e).__name__}: {e})")
expect("unlock: strict lifts src/core/** (no denyWrite, no Edit/Write)", (False, False),
       lambda: (dw_blocks(S1, WC / "src/core/a.py"), rule_blocks(S1, WC / "src/core/a.py")))
expect("unlock: strict keeps LICENSE locked", True, lambda: dw_blocks(S1, WC / "LICENSE") and rule_blocks(S1, WC / "LICENSE"))
expect("unlock: control-diff lets src/core/a.py through", False, lambda: "src/core/a.py" in cdiff(sha3))
expect("unlock: control-diff still hits LICENSE", True, lambda: "LICENSE" in cdiff(sha4))
expect("unlock: another task id gets nothing (src/core/a.py not a T-202 lock anyway, LICENSE neither)", [],
       lambda: [p for p in cdiff(sha4, "T-202") if p in ("src/core/a.py", "LICENSE")])
expect("unlock: protect_paths allows src/core/a.py after approval", "allow", lambda: pp("src/core/a.py"))
gate(WC, "G-T201-2", "unlock", "[LICENSE]")
expect("unlock: G-T201-2 (paths: [LICENSE]) answered B", (True, "rejected"), lambda: H.answer_gate(C, "G-T201-2", "B", "", "终端")[:2])
expect("unlock: rejected gate lifts nothing (LICENSE still hits)", True, lambda: "LICENSE" in cdiff(sha4))
gate(WC, "G-T201-3", "unlock", "[LICENSE]")
expect("unlock: G-T201-3 (paths: [LICENSE]) approved", True, lambda: H.answer_gate(C, "G-T201-3", "A", "", "终端")[0])
S2 = None
try:
    S2 = strict()
except Exception as e:
    print(f"  (strict_settings raised {type(e).__name__}: {e})")
expect("unlock: literal LICENSE lifted in strict", (False, False),
       lambda: (dw_blocks(S2, WC / "LICENSE"), rule_blocks(S2, WC / "LICENSE")))
expect("unlock: literal LICENSE lifted in control-diff", False, lambda: "LICENSE" in cdiff(sha4))
expect("unlock: .harness/notes.md still locked after both approvals", True,
       lambda: dw_blocks(S2, WC / ".harness/notes.md") and ".harness/notes.md" in cdiff(sha4))

# ================================================================ guard_bash：heredoc 新建门卡
TEMPLATE_BODY = ("---\nid: G-T201-5\ntask: T-201\nkind: unlock\nstatus: open\nrecommended: A\npaths: [src/core/**]\n"
                 "answer:                      # 镜像：答案只认仓库外的答案库，由控制面写；Claude 不写\n---\n\n"
                 "# G-T201-5 解锁 src/core？\n\n## 选项\n- **A（推荐）**：解锁\n- **B**：不解锁\n\n"
                 "**怎么答复：** 在 GitHub Issue 勾选 / 回复邮件，看板点选，或在你自己的终端运行 "
                 "`harness_lib.py answer G-T201-5 A [备注]`。\n")


def gb(cmd):
    data = {"tool_name": "Bash", "cwd": str(WC), "tool_input": {"command": cmd}}
    r = subprocess.run([sys.executable, "-B", str(HOOKS / "guard_bash.py")], input=json.dumps(data),
                       capture_output=True, text=True, cwd=str(WC))
    if '"deny"' in r.stdout:
        return "deny"
    return "ask" if '"ask"' in r.stdout else "allow"


def gb_reason(cmd):
    data = {"tool_name": "Bash", "cwd": str(WC), "tool_input": {"command": cmd}}
    r = subprocess.run([sys.executable, "-B", str(HOOKS / "guard_bash.py")], input=json.dumps(data),
                       capture_output=True, text=True, cwd=str(WC))
    return r.stdout


hd = lambda head, body: f"{head}\n{body}EOF"
expect("guard_bash: cat heredoc creating a gate card from the template (empty answer:) allowed", "allow",
       lambda: gb(hd("cat > .harness/gates/G-T201-5.md <<'EOF'", TEMPLATE_BODY)))
expect("guard_bash: cat <<EOF > file form allowed", "allow",
       lambda: gb(hd("cat <<'EOF' > .harness/gates/G-T201-6.md", TEMPLATE_BODY.replace("G-T201-5", "G-T201-6"))))
# v2-1：模板正文有反引号命令，必须用引号定界（第 1 轮这里是 <<EOF，见 §9）
expect("guard_bash: tee heredoc with empty answer: allowed", "allow",
       lambda: gb(hd("tee .harness/gates/G-T201-7.md >/dev/null <<'EOF'", TEMPLATE_BODY.replace("G-T201-5", "G-T201-7"))))
# 正文里不放「怎么答复」那行命令，确保拒绝来自新规则（answer: 有值），不是旧的命令匹配
body_ans = TEMPLATE_BODY.split("**怎么答复：**")[0].replace(
    "answer:                      # 镜像：答案只认仓库外的答案库，由控制面写；Claude 不写", "answer: A")
expect("guard_bash: heredoc writing answer: A into a gate card denied", "deny",
       lambda: gb(hd("cat > .harness/gates/G-T201-5.md <<'EOF'", body_ans)))
expect("guard_bash: ... reason mentions 答案库", True,
       lambda: "答案库" in gb_reason(hd("cat > .harness/gates/G-T201-5.md <<'EOF'", body_ans)))
expect("guard_bash: tee heredoc writing answer: B denied", "deny",
       lambda: gb(hd("tee .harness/gates/G-T201-7.md <<EOF", body_ans.replace("answer: A", "answer: B  # 用户说的"))))
expect("guard_bash: heredoc fed to bash still checked (answer command)", "deny",
       lambda: gb(hd("bash <<'EOF'", "python3 .claude/hooks/harness_lib.py answer G-T201-5 A\n")))
expect("guard_bash: heredoc fed to python3 still checked (record_answer)", "deny",
       lambda: gb(hd("python3 - <<'EOF'", "import harness_lib as H\nH.record_answer('.', 'G-T201-5', 'A')\n")))
expect("guard_bash: plain answer command still denied (regression)", "deny",
       lambda: gb("python3 .claude/hooks/harness_lib.py answer G-T201-5 A"))

# ################################################################ 接口约定 v2（第 2 轮：挑错 8 条）
ANS = "python3 .claude/hooks/harness_lib.py answer G-T201-5 A"
BT = "`harness_lib.py answer G-T201-5 A`\n"

# ---------------------------------------------------------------- v2-1 heredoc 放宽的回退
expect("v2-1: unquoted heredoc writing the template body (backtick command) denied", "deny",
       lambda: gb(hd("cat > .harness/gates/G-T201-8.md <<EOF", TEMPLATE_BODY.replace("G-T201-5", "G-T201-8"))))
expect("v2-1: same body with <<'EOF' allowed", "allow",
       lambda: gb(hd("cat > .harness/gates/G-T201-8.md <<'EOF'", TEMPLATE_BODY.replace("G-T201-5", "G-T201-8"))))
expect("v2-1: multi-line $( … ) in an unquoted body denied", "deny",
       lambda: gb(hd("cat > notes.txt <<EOF", "x=$(\n" + ANS + "\n)\n")))
expect("v2-1: backtick harness_lib.py answer in an unquoted body denied (no exception)", "deny",
       lambda: gb(hd("cat > notes.txt <<EOF", BT)))
expect("v2-1: function named harness_lib.py + backtick call denied", "deny",
       lambda: gb('harness_lib.py() { python3 .claude/hooks/harness_lib.py "$@"; }\n' + hd("cat > notes.txt <<EOF", BT)))
expect("v2-1: PATH=.claude/hooks + backtick call denied", "deny",
       lambda: gb("export PATH=.claude/hooks:$PATH\n" + hd("cat > notes.txt <<EOF", BT)))
expect("v2-1: $[ in an unquoted body -> whole body checked", "deny",
       lambda: gb(hd("cat > notes.txt <<EOF", "n=$[1+1]\n" + ANS + "\n")))
expect("v2-1: tee unquoted body with $( denied", "deny",
       lambda: gb(hd("tee notes.txt <<EOF", "$(\n" + ANS + "\n)\n")))
expect("v2-1 control: unquoted body with no $( ` $[ is file content", "allow",
       lambda: gb(hd("cat > notes.txt <<EOF", "说明：" + ANS + " 由你在终端执行\n")))
expect("v2-1: written then run in the same command (bash /tmp/x.sh) denied", "deny",
       lambda: gb(hd("cat <<'EOF' > /tmp/t021-a.sh", ANS + "\n") + "\nbash /tmp/t021-a.sh"))
expect("v2-1: written then run (sh ./a.sh) denied", "deny",
       lambda: gb(hd("cat > a.sh <<'EOF'", ANS + "\n") + "\nsh ./a.sh"))
expect("v2-1: written then sourced (. a.sh) denied", "deny",
       lambda: gb(hd("tee a.sh >/dev/null <<'EOF'", ANS + "\n") + "\n. a.sh"))
expect("v2-1: && bash on the opening line denied", "deny",
       lambda: gb(hd("cat <<'EOF' > /tmp/t021-b.sh && bash /tmp/t021-b.sh", ANS + "\n")))

# ---------------------------------------------------------------- v2-6 写答案的拒绝要规范化
expect("v2-6: cd .harness/gates && cat > G-…md with answer: A denied", "deny",
       lambda: gb(hd("cd .harness/gates && cat > G-T201-5.md <<'EOF'", body_ans)))
expect("v2-6: cd .harness/gates; cat > G-…md with answer: A denied", "deny",
       lambda: gb(hd("cd .harness/gates; cat > G-T201-5.md <<'EOF'", body_ans)))
expect("v2-6: ./.harness//gates/./G-…md denied", "deny",
       lambda: gb(hd("cat > ./.harness//gates/./G-T201-5.md <<'EOF'", body_ans)))
expect("v2-6: src/../.harness/gates/G-…md denied", "deny",
       lambda: gb(hd("cat > src/../.harness/gates/G-T201-5.md <<'EOF'", body_ans)))
expect("v2-6: quoted target path denied", "deny",
       lambda: gb(hd("cat > \".harness/gates/G-T201-5.md\" <<'EOF'", body_ans)))
expect('v2-6: "answer": A (quoted key) denied', "deny",
       lambda: gb(hd("cat > .harness/gates/G-T201-5.md <<'EOF'", body_ans.replace("answer: A", '"answer": A'))))
expect("v2-6: 'answer' : B (quoted key, space) denied", "deny",
       lambda: gb(hd("cat > .harness/gates/G-T201-5.md <<'EOF'", body_ans.replace("answer: A", "'answer' : B"))))
expect("v2-6: ... reason mentions 答案库", True,
       lambda: "答案库" in gb_reason(hd("cd .harness/gates && cat > G-T201-5.md <<'EOF'", body_ans)))

# ---------------------------------------------------------------- v2-2 protect_paths 用 locked_paths 并集
D = mkrepo("u2", [("T-301", "in_progress")])
(D / "LICENSE").write_text("L\n", encoding="utf-8")
card(D, "T-301", "in_progress", allowed="src/**", locked="LICENSE, .harness/**")
git(D, "add", "-A"); git(D, "commit", "-qm", "init")
WD = TMP / "u2-T301"
git(D, "worktree", "add", "-q", "-b", "task/T-301-x", str(WD))
WD = WD.resolve()
card(WD, "T-301", "in_progress", allowed="src/**, LICENSE", locked="")   # Claude 改了自己的卡：去掉锁
expect("v2-2: lock dropped from the worktree card still holds (LICENSE)", "deny", lambda: pp("LICENSE", cwd=WD))
expect("v2-2: main card's .harness/** still locks decisions.md", "deny", lambda: pp(".harness/decisions.md", cwd=WD))
expect("v2-2: own card still writable under the main card's .harness/**", "allow", lambda: pp(".harness/tasks/T-301-x.md", cwd=WD))

# ---------------------------------------------------------------- v2-5 ctl 门卡不是自己的文件，只在主仓库解析
expect("v2-5: is_own_path own card / gate", (True, True),
       lambda: (H.is_own_path("T-201", ".harness/tasks/T-201-x.md"), H.is_own_path("T-201", ".harness/gates/G-T201-1.md")))
expect("v2-5: is_own_path excludes ctl gates", [False, False, False],
       lambda: [H.is_own_path("T-201", p) for p in (".harness/gates/G-T201-ctl.md", ".harness/gates/G-T201-ctl-2.md",
                                                     ".harness/gates/G-T201-ctl/x.png")])
expect("v2-5: protect_paths: worktree may not write its G-T201-ctl.md (locked .harness/**)", "deny",
       lambda: pp(".harness/gates/G-T201-ctl.md"))
expect("v2-5: protect_paths: nor G-T201-ctl-2.md", "deny", lambda: pp(".harness/gates/G-T201-ctl-2.md"))
CTL_TXT = "---\nid: G-T201-ctl\ntask: T-201\nkind: unlock\nstatus: open\nrecommended: A\n---\n\n# G-T201-ctl 批准？\n\n- **A（推荐）**：批准\n- **B**：退回\n"
sha5 = commit_wc("plant ctl", {".harness/gates/G-T201-ctl.md": CTL_TXT})
expect("v2-5: control-diff: planted G-T201-ctl.md counts as a locked_paths hit", True,
       lambda: ".harness/gates/G-T201-ctl.md" in cdiff(sha5))
S3 = None
try:
    S3 = strict()
except Exception as e:
    print(f"  (strict_settings raised {type(e).__name__}: {e})")
expect("v2-5: strict: existing G-T201-ctl.md in denyWrite + Edit/Write", (True, True),
       lambda: (dw_blocks(S3, WC / ".harness/gates/G-T201-ctl.md"), rule_blocks(S3, WC / ".harness/gates/G-T201-ctl.md")))
expect("v2-5: strict: own gate G-T201-1.md still free", (False, False),
       lambda: (dw_blocks(S3, WC / ".harness/gates/G-T201-1.md"), rule_blocks(S3, WC / ".harness/gates/G-T201-1.md")))
expect("v2-5: find_gate_card ignores a ctl card in the task's worktree", None, lambda: H.find_gate_card(C, "G-T201-ctl"))
expect("v2-5: find_gate_card finds a ctl card in main", True,
       lambda: H.find_gate_card(A, "G-T009-ctl") == A / ".harness/gates/G-T009-ctl.md")

# ---------------------------------------------------------------- v2-4 ctl：is_ctl_gid、next-ctl-gid、有 ctl 就不转 ready
expect("v2-4: is_ctl_gid", [True, True, True, False, False, False],
       lambda: [H.is_ctl_gid(g) for g in ("G-T009-ctl", "G-T009-ctl-2", "G-T1234-ctl-10", "G-T009-1", "G-T009-ctlx", "G-GROOM-ctl")])
rc, out, err = cli(A, "next-ctl-gid", "T-030")
expect("v2-4: next-ctl-gid with no ctl yet -> G-T030-ctl", (0, "G-T030-ctl"), (rc, out.strip()))
rc, out, err = cli(A, "next-ctl-gid", "T-009")
expect("v2-4: next-ctl-gid when G-T009-ctl exists -> G-T009-ctl-2", (0, "G-T009-ctl-2"), (rc, out.strip()))
gate(A, "G-T009-ctl-2", "unlock")
expect("v2-4: G-T009-ctl-2 (no paths) snapshotted like a ctl gate", True, lambda: H.snapshot_meta(A, "G-T009-ctl-2") is not None)
rc, out, err = cli(A, "next-ctl-gid", "T-009")
expect("v2-4: next-ctl-gid after -ctl-2 -> G-T009-ctl-3", (0, "G-T009-ctl-3"), (rc, out.strip()))
rc, out, err = cli(A, "next-ctl-gid", "foo")
expect("v2-4: next-ctl-gid bad task id -> exit 2", 2, rc)
expect("v2-4: harness-loop ctl_block asks next-ctl-gid", True,
       "next-ctl-gid" in (PKG / "scripts/harness-loop.sh").read_text(encoding="utf-8"))

with open(A / ".harness/backlog.md", "a", encoding="utf-8") as f:
    for t, st in (("T-012", "in_progress"), ("T-013", "review"), ("T-014", "integrated"), ("T-016", "blocked"),
                  ("T-017", "blocked"), ("T-019", "blocked")):
        f.write(f"- {t} | {st} | P1 | demo {t} | deps: - | auto_ok: no | owner: -\n")
card(A, "T-017", "blocked"); gate(A, "G-T017-ctl", "unlock"); gate(A, "G-T017-1", "ambiguity")
expect("v2-4: answered (approved) ctl gate recorded", True, lambda: H.answer_gate(A, "G-T017-ctl", "A", "", "终端")[0])
# v3-2 取代 v2-4 这里的期望（§9）：已答复、且不比最新答复新的 ctl 门卡不挡
time.sleep(1.1)
r = H.answer_gate(A, "G-T017-1", "A", "", "终端")
expect("v3-2 (was v2-4): ctl answered A earlier, then the other gate answered -> unblocked", (True, "answered", "T-017"), lambda: r)
expect("v3-2 (was v2-4): ... card and backlog ready", ("ready", "ready"), lambda: (status(A, "T-017"), blog(A, "T-017")))
card(A, "T-019", "blocked"); gate(A, "G-T019-ctl-2", "unlock"); gate(A, "G-T019-1", "ambiguity")
H.answer_gate(A, "G-T019-ctl-2", "B", "", "终端")
time.sleep(1.1)
expect("v3-2 (was v2-4): -ctl-2 answered B earlier, then the other gate answered -> ready", ("ready", "ready"),
       lambda: (H.answer_gate(A, "G-T019-1", "A", "", "终端") and None) or (status(A, "T-019"), blog(A, "T-019")))

# ---------------------------------------------------------------- v2-3 只认主仓库 backlog 行 blocked
for t, row in (("T-012", "in_progress"), ("T-013", "review"), ("T-014", "integrated")):
    card(A, t, "blocked"); gate(A, f"G-{t.replace('-', '')}-1", "ambiguity")
    r = H.answer_gate(A, f"G-{t.replace('-', '')}-1", "A", "", "终端")
    expect(f"v2-3: card blocked but backlog row {row}: no transition", (True, "answered", None), lambda: r)
    expect(f"v2-3: ... row {row} not overwritten, card stays blocked", (row, "blocked"), lambda: (blog(A, t), status(A, t)))

# ---------------------------------------------------------------- v2-7 被拒的 unlock 之后不转 ready
card(A, "T-016", "blocked"); gate(A, "G-T016-1", "unlock", "[src/T-016/**]"); gate(A, "G-T016-2", "ambiguity")
H.answer_gate(A, "G-T016-1", "B", "", "终端")
r = H.answer_gate(A, "G-T016-2", "A", "", "终端")
expect("v2-7: after a rejected unlock, answering the other gate does not unblock", (True, "answered", None), lambda: r)
expect("v2-7: ... card and backlog stay blocked", ("blocked", "blocked"), lambda: (status(A, "T-016"), blog(A, "T-016")))
expect("v2-7: ... not dispatched", False, lambda: "T-016" in H.pick_batch(A, 30))

# ---------------------------------------------------------------- v2-8 waiting_human 也查主仓库的 open 门卡
with open(B / ".harness/backlog.md", "a", encoding="utf-8") as f:
    f.write("- T-022 | waiting_human | P1 | demo T-022 | deps: - | auto_ok: no | owner: -\n")
card(B, "T-022", "claimed")
WB2 = TMP / "wt-T022"
git(B, "worktree", "add", "-q", "-b", "task/T-022-x", str(WB2))
WB2 = WB2.resolve()
card(WB2, "T-022", "waiting_human"); gate(WB2, "G-T022-1", "ambiguity")
gate(B, "G-T022-2", "ambiguity")                     # 还开着，只在主仓库
r = H.answer_gate(B, "G-T022-1", "A", "", "终端")
expect("v2-8: open gate in main keeps a waiting task waiting", (True, "answered", None), lambda: r)
expect("v2-8: ... worktree card stays waiting_human", "waiting_human", lambda: status(WB2, "T-022"))
expect("v2-8: ... no resume queued", False, lambda: (H.answers_dir(B) / "G-T022-1.resume").exists())
r = H.answer_gate(B, "G-T022-2", "A", "", "终端")
expect("v2-8 control: last gate answered -> resumes", (True, "answered", "T-022"), lambda: r)

ta_hg = (PKG / ".claude/skills/human-gate/SKILL.md").read_text(encoding="utf-8")
expect("v2-1: human-gate SKILL tells to write gate cards with <<'EOF'", True, "<<'EOF'" in ta_hg)

# ################################################################ 接口约定 v3（第 3 轮：verifier A2）
with open(A / ".harness/backlog.md", "a", encoding="utf-8") as f:
    for t in ("T-060", "T-061", "T-062", "T-063", "T-064", "T-065"):
        f.write(f"- {t} | blocked | P1 | demo {t} | deps: - | auto_ok: no | owner: -\n")
    f.write("- T-066 | in_progress | P1 | demo T-066 | deps: - | auto_ok: no | owner: -\n")

# ---------------------------------------------------------------- v3-1（N1）被拒之后有更晚的批准 → 放行
card(A, "T-060", "blocked"); gate(A, "G-T060-1", "unlock", "[src/T-060/**]"); gate(A, "G-T060-2", "unlock", "[src/T-060/a/**]")
r = H.answer_gate(A, "G-T060-1", "B", "太宽", "终端")
expect("v3-1: unlock rejected while another gate is open: stays blocked", ("blocked", "blocked"),
       lambda: (status(A, "T-060"), blog(A, "T-060")))
time.sleep(1.1)
r = H.answer_gate(A, "G-T060-2", "A", "", "终端")
expect("v3-1: later narrower unlock approved -> settle unblocks", (True, "approved", "T-060"), lambda: r)
expect("v3-1: ... card and backlog both ready", ("ready", "ready"), lambda: (status(A, "T-060"), blog(A, "T-060")))
expect("v3-1: ... dispatchable", True, lambda: "T-060" in H.pick_batch(A, 40))
# 批准在拒绝之前：不算；之后只答了非批准类 → 保持 blocked
card(A, "T-061", "blocked"); gate(A, "G-T061-1", "unlock", "[src/T-061/**]"); gate(A, "G-T061-2", "unlock", "[src/T-061/b/**]")
gate(A, "G-T061-3", "ambiguity")
H.answer_gate(A, "G-T061-1", "A", "", "终端"); time.sleep(1.1)
H.answer_gate(A, "G-T061-2", "B", "", "终端"); time.sleep(1.1)
r = H.answer_gate(A, "G-T061-3", "A", "", "终端")
expect("v3-1: approval BEFORE the rejection does not lift it; later ambiguity answer -> stays blocked",
       ((True, "answered", None), "blocked", "blocked"), lambda: (r, status(A, "T-061"), blog(A, "T-061")))

# ---------------------------------------------------------------- v3-2（N2）ctl 门卡
card(A, "T-062", "blocked"); gate(A, "G-T062-ctl", "unlock"); gate(A, "G-T062-1", "unlock", "[src/T-062/**]")
H.answer_gate(A, "G-T062-ctl", "B", "", "终端"); time.sleep(1.1)
r = H.answer_gate(A, "G-T062-1", "A", "", "终端")
expect("v3-2: ctl answered B, later unlock answered A -> unblocked", (True, "approved", "T-062"), lambda: r)
expect("v3-2: ... card and backlog ready", ("ready", "ready"), lambda: (status(A, "T-062"), blog(A, "T-062")))
card(A, "T-063", "blocked"); gate(A, "G-T063-ctl", "unlock"); gate(A, "G-T063-1", "ambiguity")
r = H.answer_gate(A, "G-T063-1", "A", "", "终端")
expect("v3-2: an OPEN ctl gate still blocks", ((True, "answered", None), "blocked", "blocked"),
       lambda: (r, status(A, "T-063"), blog(A, "T-063")))
# ctl 门卡比最新答复新（答复之后才被 ctl 拦下），即使已答复也挡
card(A, "T-064", "blocked"); gate(A, "G-T064-1", "ambiguity")
H.set_backlog_status(A, "T-064", "in_progress")
H.answer_gate(A, "G-T064-1", "A", "", "终端")                 # 行是 in_progress：不转（v2-3）
time.sleep(1.1)
gate(A, "G-T064-ctl", "unlock"); H.answer_gate(A, "G-T064-ctl", "B", "", "终端")
H.set_backlog_status(A, "T-064", "blocked")
expect("v3-2: ctl gate newer than the latest answer blocks release_blocked", False, lambda: H.release_blocked(A, "T-064"))
expect("v3-2: ... nothing changed", ("blocked", "blocked"), lambda: (status(A, "T-064"), blog(A, "T-064")))

# ---------------------------------------------------------------- v3-0 / v3-3 release_blocked 与 CLI
card(A, "T-065", "blocked")
expect("v3-0: blocked task with no gates is not released", False, lambda: H.release_blocked(A, "T-065"))
rc, out, err = cli(A, "release-blocked", "T-065")
expect("v3-0: CLI release-blocked with nothing to release -> exit 1", 1, rc)
rc, out, err = cli(A, "release-blocked", "foo")
expect("v3-0: CLI release-blocked bad id -> exit 2", 2, rc)
# 竞态：答复时行是 in_progress（会话还在跑），会话结束时卡是 blocked，finish 记 blocked → 立即复核
card(A, "T-066", "in_progress"); gate(A, "G-T066-1", "ambiguity")
r = H.answer_gate(A, "G-T066-1", "B", "", "终端")
expect("v3-3: answer while the row is in_progress: no transition yet", ((True, "answered", None), "in_progress"),
       lambda: (r, blog(A, "T-066")))
card(A, "T-066", "blocked"); H.set_backlog_status(A, "T-066", "blocked")   # 会话结束：finish 记 blocked
rc, out, err = cli(A, "release-blocked", "T-066")
expect("v3-3: CLI release-blocked releases it (exit 0, prints ready)", (0, True), (rc, "ready" in out))
expect("v3-3: ... card and backlog ready", ("ready", "ready"), lambda: (status(A, "T-066"), blog(A, "T-066")))
expect("v3-3: ... dispatchable", True, lambda: "T-066" in H.pick_batch(A, 40))
expect("v3-3: harness-loop finish() calls release-blocked", True,
       "release-blocked" in (PKG / "scripts/harness-loop.sh").read_text(encoding="utf-8"))

# ================================================================ skills 文案
ta = (PKG / ".claude/skills/task-align/SKILL.md").read_text(encoding="utf-8").splitlines()
hg = (PKG / ".claude/skills/human-gate/SKILL.md").read_text(encoding="utf-8").splitlines()
expect("task-align SKILL: says not to put .harness/** into locked_paths", True,
       any("locked_paths" in l and ".harness/**" in l and "不" in l for l in ta))
expect("task-align SKILL: no line lists .harness/** as something to lock", False,
       any(re.search(r"locked_paths:\s*\[[^\]]*\.harness/\*\*", l) for l in ta))
expect("human-gate SKILL: unlock gates must carry paths:", True, any("unlock" in l and "paths:" in l for l in hg))
expect("human-gate SKILL: answered gates turn blocked tasks ready", True, any("blocked" in l and "ready" in l for l in hg))

print(f"{N - FAILS}/{N} passed")
sys.exit(1 if FAILS else 0)
PY
