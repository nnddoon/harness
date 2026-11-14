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
import contextlib, io, json, os, re, subprocess, sys, traceback
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
expect("guard_bash: tee heredoc with empty answer: allowed", "allow",
       lambda: gb(hd("tee .harness/gates/G-T201-7.md >/dev/null <<EOF", TEMPLATE_BODY.replace("G-T201-5", "G-T201-7"))))
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
