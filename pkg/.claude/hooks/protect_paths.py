#!/usr/bin/env python3
"""PreToolUse(Edit|Write|NotebookEdit): enforce task scope + frozen paths.

Deny rules (in order):
  1. In a linked worktree, never write into the main checkout.
  2. .harness/locks.txt is append-only.
  3. .harness/backlog.md is single-writer: not editable from a linked worktree.
  4. Paths in .harness/locks.txt or task `locked_paths` (unless in task `unlock`
     AND an approved `kind: unlock` gate exists for the task). The task's own card, handoff and
     gate cards (H.is_own_path; not the scheduler's G-Txxx-ctl*) are exempt from its locked_paths (main card ∪
     worktree card), not from locks.txt.
  5a. A task session never changes its own card's allowed_paths / locked_paths / unlock / auto_ok / risk (T-024).
  5. If the task card (main checkout's; the worktree's only when main has none) has non-empty `allowed_paths`,
     paths outside it (harness bookkeeping under .harness/ is always allowed, except rule 2/3).
  0. HARNESS_MODE=groom|review: only .harness/** is writable.
  0b. No new SUMMARY/REPORT/NOTES/FINDINGS/ANALYSIS/PROGRESS/STATUS/HANDOFF/TODO*.md outside .harness/.
  6. Dependency manifests (package.json, requirements*.txt, go.mod, ...) need an approved unlock gate.
  7. Tester/builder split (task card test_owner: tester, the default): only the `tester` subagent edits
     test files (.harness/test-paths.txt or defaults), and it edits nothing else.
Set HARNESS_GUARD=off to disable (e.g. while editing the harness itself by hand).
"""
import json
import os
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ in the repo/worktrees
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness_lib as H  # noqa: E402

DEP_MANIFESTS = ["**/package.json", "**/package-lock.json", "**/pnpm-lock.yaml", "**/yarn.lock", "**/bun.lockb",
                 "**/requirements*.txt", "**/pyproject.toml", "**/poetry.lock", "**/Pipfile", "**/Pipfile.lock",
                 "**/uv.lock", "**/go.mod", "**/go.sum", "**/Cargo.toml", "**/Cargo.lock", "**/Gemfile",
                 "**/Gemfile.lock", "**/composer.json", "**/composer.lock", "**/pom.xml", "**/build.gradle*"]
DEFAULT_TEST_GLOBS = ["**/test/**", "**/tests/**", "**/__tests__/**", "**/e2e/**", "**/*.test.*", "**/*.spec.*",
                      "**/*_test.*", "**/test_*.py", "**/conftest.py"]


def test_globs(root: Path) -> list:
    f = root / ".harness" / "test-paths.txt"
    if f.exists():
        g = [l.strip() for l in f.read_text(encoding="utf-8").splitlines() if l.strip() and not l.startswith("#")]
        if g:
            return g
    return DEFAULT_TEST_GLOBS


BOOKKEEPING_OK = [".harness/tasks/**", ".harness/handoffs/**", ".harness/gates/**",
                  ".harness/decisions.md", ".harness/current"]


def scope_fields_changed(data: dict, ti: dict, abs_t: Path, mc: Path, tid: str) -> list:
    """Scope fields (H.SCOPE_FIELDS) this Write / Edit would change in the task's own card; [] when it changes none
    or the Edit cannot apply (old_string not found: left to Edit's own error)."""
    tool = data.get("tool_name")
    try:
        if abs_t.exists():
            old = abs_t.read_text(encoding="utf-8")
        else:
            mcard = H.task_card_path(mc, tid)
            old = mcard.read_text(encoding="utf-8") if mcard else ""
    except (OSError, UnicodeDecodeError):
        old = ""
    if tool == "Write":
        new = str(ti.get("content") or "")
    elif tool == "Edit":
        a, b = ti.get("old_string"), ti.get("new_string")
        if not isinstance(a, str) or not a or not isinstance(b, str) or a not in old:
            return []
        new = old.replace(a, b) if ti.get("replace_all") else old.replace(a, b, 1)
    else:
        return []
    return H.scope_fields_diff(old, new)


_HOOK: dict = {}  # this call's hook input, for the audit line


def deny(reason: str) -> None:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "[harness] " + reason,
    }}, ensure_ascii=False), flush=True)
    try:  # the verdict goes to the audit log (T-012)
        H.audit_hook(_HOOK, verdict="deny", reason=reason)
    except Exception:
        pass
    sys.exit(0)


def main() -> None:
    if os.environ.get("HARNESS_GUARD") == "off":
        return
    data = json.load(sys.stdin)
    _HOOK.update(data if isinstance(data, dict) else {})
    ti = data.get("tool_input") or {}
    target = ti.get("file_path") or ti.get("notebook_path") or ti.get("path")
    if not target:
        return
    cwd = data.get("cwd") or os.getcwd()
    root = H.repo_root(cwd)
    if not root:
        return
    abs_t = Path(target) if os.path.isabs(target) else Path(cwd) / target
    abs_t = Path(os.path.realpath(abs_t))
    root_r = Path(os.path.realpath(root))

    # 1. worktree must not write into main checkout
    if H.is_linked_worktree(cwd):
        mc = H.main_checkout(cwd)
        if mc:
            mc_r = Path(os.path.realpath(mc))
            if root_r not in abs_t.parents and abs_t != root_r and (mc_r == abs_t or mc_r in abs_t.parents):
                deny(f"你在 worktree {root_r} 中，不允许修改主仓库文件 {abs_t}。"
                     "需要改 backlog/全局状态时写进本任务的交接包，由控制塔会话同步。")

    try:
        rel = abs_t.relative_to(root_r).as_posix()
    except ValueError:
        return  # outside repo: leave to normal permission system

    # 0. groom / review sessions may only touch harness bookkeeping
    if os.environ.get("HARNESS_MODE") in ("groom", "review") and not (
            rel.startswith(".harness/") or rel.startswith("docs/specs/")
            or re.match(r"^\.claude/worktrees/[^/]+/\.harness/", rel)):
        deny(f"当前是 {os.environ.get('HARNESS_MODE')} 模式（规划/审核），只允许写 .harness/、docs/specs/ 和各 worktree 的 .harness/，不改业务代码：{rel}")

    # 0b. no stray report files: content belongs in the task card / handoff / reply
    #     (idea from danyuchn/claude-work-mode scratch-doc-guard, MIT)
    if (data.get("tool_name") == "Write" and not abs_t.exists() and not rel.startswith(".harness/")
            and re.match(r"^(SUMMARY|REPORT|NOTES|FINDINGS|ANALYSIS|PROGRESS|STATUS|HANDOFF|TODO)[-_A-Za-z0-9]*\.md$",
                         abs_t.name, re.I)):
        deny(f"不要新建 {rel}。这类总结/进度/笔记写进当前任务卡（「7. 当前进展」「8. 发现的问题」）、"
             "交接包 .harness/handoffs/ 或直接写在回复里；中间结果放 /tmp。")

    # 2. locks.txt append-only
    if rel == ".harness/locks.txt":
        old_file = (root_r / rel).read_text(encoding="utf-8") if (root_r / rel).exists() else ""
        tool = data.get("tool_name")
        if tool == "Write" and ti.get("content", "").startswith(old_file):
            return
        if tool == "Edit" and ti.get("new_string", "").startswith(ti.get("old_string", "\0")) \
                and not ti.get("replace_all"):
            return
        deny("`.harness/locks.txt` 只允许追加新行（Edit 时 new_string 必须以 old_string 开头）。"
             "要移除冻结请开 /human-gate unlock。")

    # 3. backlog single writer
    if rel == ".harness/backlog.md" and H.is_linked_worktree(cwd):
        deny("backlog 只由主仓库的控制塔会话修改（单写者）。把需要新增/更新的条目写进交接包「遗留问题」。")

    branch = H.current_branch(cwd)
    tid = H.task_id_for(root_r, branch)
    fm = {}
    card = H.task_card_path(root_r, tid) if tid else None
    if card:
        fm = H.read_frontmatter(card)
    # T-010: what an unlock gate opens is what the task card listed when the control plane first saw the gate
    # (its meta snapshot), and only once the human answered A in the answers store; later card edits add nothing.
    unlock = H.approved_unlock_paths(H.store_main(root_r), tid) if tid else []
    unlock_ok = bool(unlock)

    # 4. frozen paths
    for pat, why in H.read_locks(root_r):
        if H.glob_to_regex(H._norm(pat)).match(rel):
            if H.matches_any(rel, unlock) and unlock_ok:
                return
            deny(f"`{rel}` 已被冻结（locks.txt: {pat} {why}）。如必须修改：在任务卡 unlock: 加上该路径，"
                 "并通过 /human-gate unlock 获得批准。")
    # task locked_paths = main checkout card ∪ worktree card (dropping a lock from its own card changes nothing);
    # the task's own card / handoff / gate cards are never locked by them (T-021, F-9), the ctl gate card is
    mc = H.main_checkout(cwd) or root_r
    hit = H.matches_any(rel, H.task_locked_paths(root_r, Path(mc), tid) + H._card_locks(fm)) if tid else None
    if hit and not H.is_own_path(tid, rel) and not (H.matches_any(rel, unlock) and unlock_ok):
        deny(f"`{rel}` 在任务 {tid} 的 locked_paths（{hit}）中。")

    # 5a. the task's own card: its scope fields are control-plane data (T-024), a task session never changes them
    if tid and (H.is_linked_worktree(cwd) or tid in (branch or "")) and re.fullmatch(
            rf"\.harness/tasks/{re.escape(tid)}(-[^/]*)?\.md", rel):
        changed = scope_fields_changed(data, ti, abs_t, Path(mc), tid)
        if changed:
            deny(f"不能在任务分支里改本任务卡的范围字段（{'、'.join(changed)}）：范围以 main 上的任务卡为准，分支里改了也不算数。"
                 "需要扩大范围：在任务卡「9. 范围变更」写明要加的路径和原因，再开 /human-gate（unlock 或 ambiguity），"
                 "由人在 main 上改卡并提交。")

    # 5. scope
    if H.matches_any(rel, BOOKKEEPING_OK):
        return

    # 6. new dependencies need a human: manifests are implicitly frozen (unlock gate to change)
    if tid and H.matches_any(rel, DEP_MANIFESTS) and not (H.matches_any(rel, unlock) and unlock_ok):
        deny(f"`{rel}` 是依赖清单：新增或升级依赖需要你确认。请 /human-gate unlock 说明要加的包、版本、许可证、"
             "为什么现有依赖不够；批准后在任务卡 unlock: 写上这个路径再改。")

    # 7. tester / builder split: only the `tester` subagent writes tests; it writes nothing else
    if tid and (fm.get("test_owner") or "tester") == "tester":
        is_test = bool(H.matches_any(rel, test_globs(root_r)))
        agent = (data.get("agent_type") or "").lower()
        if agent == "tester" and not is_test:
            deny(f"tester 只写测试，不改源码：`{rel}`。把需要的实现写进任务卡「7. 当前进展」交给 builder。")
        if agent != "tester" and is_test:
            deny(f"`{rel}` 是测试文件：测试只由 tester 子代理按验收标准编写，实现方不能改测试（防止改测试凑通过）。"
                 "需要新增或调整测试：调用 tester 子代理并说明原因；确实是测试本身写错，写进「7. 当前进展」由 tester 修。")
    # allowed_paths come from the main checkout's card (T-024); the worktree card only when main has none
    main_card = H.task_card_path(Path(mc), tid) if tid else None
    scope_fm = H.read_frontmatter(main_card) if main_card else fm
    allowed = scope_fm.get("allowed_paths") or []
    allowed = [allowed] if isinstance(allowed, str) else allowed
    if allowed and not H.matches_any(rel, allowed):
        deny(f"`{rel}` 不在任务 {tid} 的 allowed_paths 内 {allowed}（以主仓库任务卡为准）。如确需修改：在任务卡「9. 范围变更」"
             "写明原因，再开 /human-gate（unlock 或 ambiguity），由人在 main 上改卡并提交。")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # never break the session because of a hook bug
        print(f"[harness] protect_paths error: {e}", file=sys.stderr)
        sys.exit(0)
